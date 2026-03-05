defmodule Orquesta.Runtime.InternalDrain do
  @moduledoc """
  Internal drain implementation backed by `Task.Supervisor`.

  On startup, performs reconciliation per Section 6.2:
  - Queries outbox entries where `status == :running AND scope_type == :agent
    AND scope_id == agent_instance_id AND agent_revision == committed_revision`
  - Resets each to `:pending` and resubmits

  Implements `Orquesta.DrainBehaviour`. Directive content is always read
  from the outbox; it is never passed inline.
  """

  use GenServer

  @behaviour Orquesta.DrainBehaviour

  @dialyzer [
    {:nowarn_function, submit: 2},
    {:nowarn_function, cancel: 2},
    {:nowarn_function, status: 1}
  ]

  alias Orquesta.Types
  alias Orquesta.OutboxEntry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    agent_instance_id = Keyword.fetch!(opts, :agent_instance_id)
    name = via(agent_instance_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns a via tuple for Registry lookup by agent_instance_id."
  @spec via(String.t()) :: {:via, module(), term()}
  def via(agent_instance_id) do
    {:via, Registry, {Orquesta.Registry, {__MODULE__, agent_instance_id}}}
  end

  @impl Orquesta.DrainBehaviour
  @spec submit(Types.outbox_entry_id(), keyword()) :: :ok | {:error, term()}
  def submit(outbox_entry_id, opts) do
    agent_instance_id = Keyword.fetch!(opts, :agent_instance_id)
    GenServer.call(via(agent_instance_id), {:submit, outbox_entry_id})
  end

  @impl Orquesta.DrainBehaviour
  @spec cancel(Types.outbox_entry_id(), keyword()) :: :ok | {:error, term()}
  def cancel(outbox_entry_id, opts) do
    agent_instance_id = Keyword.fetch!(opts, :agent_instance_id)
    GenServer.call(via(agent_instance_id), {:cancel, outbox_entry_id})
  end

  @impl Orquesta.DrainBehaviour
  @spec status(Types.outbox_entry_id()) :: Types.outbox_status() | {:error, :not_found}
  def status(outbox_entry_id, opts \\ []) do
    agent_instance_id = Keyword.fetch!(opts, :agent_instance_id)
    GenServer.call(via(agent_instance_id), {:status, outbox_entry_id})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      agent_instance_id: Keyword.fetch!(opts, :agent_instance_id),
      committed_revision: Keyword.get(opts, :committed_revision, 0),
      outbox: Keyword.fetch!(opts, :outbox),
      codec: Keyword.fetch!(opts, :codec),
      task_supervisor: nil
    }

    {:ok, state, {:continue, :start_task_supervisor}}
  end

  @impl GenServer
  def handle_continue(:start_task_supervisor, state) do
    {:ok, task_sup} = Task.Supervisor.start_link()
    new_state = %{state | task_supervisor: task_sup}
    :ok = reconcile(new_state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task crashed — outbox entry remains :running.
    # Startup reconciliation on next restart will reset and resubmit.
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:submit, outbox_entry_id}, _from, %{outbox: outbox, codec: codec, task_supervisor: task_sup} = state) do
    # Section 6.1/6.2: Read directive from outbox, transition to :running, then execute
    result =
      case outbox.get_entry(outbox_entry_id) do
        {:ok, entry} ->
          if OutboxEntry.terminal?(entry) do
            # Terminal entries cannot be retried
            :ok
          else
            # Transition to :running atomically with job acquisition
            case outbox.transition(outbox_entry_id, :running) do
              :ok ->
                # Spawn async task to execute the directive
                Task.Supervisor.start_child(task_sup, fn ->
                  execute_directive(entry, outbox, codec)
                end)

                :ok

              {:error, :terminal} ->
                # Already terminal, treat as success (idempotent)
                :ok

              {:error, reason} ->
                {:error, reason}
            end
          end

        {:error, :not_found} ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:cancel, outbox_entry_id}, _from, %{outbox: outbox} = state) do
    # Section 6.1: Attempt to cancel
    # Best-effort: if already running/terminal, still return :ok
    result =
      case outbox.transition(outbox_entry_id, :cancelled) do
        :ok -> :ok
        {:error, :terminal} -> :ok
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:status, outbox_entry_id}, _from, %{outbox: outbox} = state) do
    result =
      case outbox.get_entry(outbox_entry_id) do
        {:ok, entry} -> entry.status
        {:error, :not_found} -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  # Execute the directive and update outbox status
  defp execute_directive(entry, outbox, codec) do
    # Decode and execute the directive
    decoded = codec.decode_directive(entry.encoded_directive)

    context = %{
      directive_id: entry.directive_id,
      agent_instance_id: entry.scope_id,
      agent_revision: entry.agent_revision,
      correlation_id: decoded.correlation_id,
      causation_id: decoded.causation_id,
      trace_context: entry.trace_context
    }

    result = decoded.module.execute(decoded.args, context)

    # Update outbox status based on result
    new_status =
      case result do
        :ok -> :completed
        {:error, _reason} -> :failed
      end

    _ = outbox.transition(entry.directive_id, new_status)

    # Emit outcome signal if configured (handled by plan meta)
    result
  end

  @spec reconcile(%{agent_instance_id: String.t(), committed_revision: non_neg_integer(), outbox: module()}) ::
          :ok
  defp reconcile(state) do
    # Section 6.2 startup reconciliation:
    # Query entries where status == :running AND scope_type == :agent
    # AND scope_id == agent_instance_id AND agent_revision == committed_revision
    running_entries =
      state.outbox.query_by_status_scope_revision(
        :running,
        :agent,
        state.agent_instance_id,
        state.committed_revision
      )

    Enum.each(running_entries, fn entry ->
      # Reset to :pending
      :ok = state.outbox.transition(entry.directive_id, :pending)
      # Resubmit via this drain instance
      submit(entry.directive_id, agent_instance_id: state.agent_instance_id)
    end)

    :ok
  end
end
