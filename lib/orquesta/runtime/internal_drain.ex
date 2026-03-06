defmodule Orquesta.Runtime.InternalDrain do
  @moduledoc """
  Internal drain implementation backed by `Task.Supervisor`.

  Reconciliation (Section 6.2) is triggered by `AgentRuntime` via `reconcile/2`
  after startup recovery completes and the correct `committed_revision` is known.
  This avoids the sequencing problem where the drain starts before the runtime
  has determined what revision it is recovering to.

  Implements `Orquesta.DrainBehaviour`. Directive content is always read
  from the outbox; it is never passed inline.

  Registered in `Orquesta.Registry` by `{__MODULE__, agent_instance_id}` so
  that multiple drain instances can run concurrently without name collisions.
  """

  use GenServer

  @behaviour Orquesta.DrainBehaviour

  @dialyzer [
    {:nowarn_function, submit: 2},
    {:nowarn_function, cancel: 2},
    {:nowarn_function, status: 2},
    {:nowarn_function, reconcile: 2}
  ]

  alias Orquesta.Types
  alias Orquesta.OutboxEntry

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    agent_instance_id = Keyword.fetch!(opts, :agent_instance_id)
    GenServer.start_link(__MODULE__, opts, name: via(agent_instance_id))
  end

  @doc "Returns the via tuple used to locate this drain in `Orquesta.Registry`."
  @spec via(Types.agent_instance_id()) :: {:via, module(), term()}
  def via(agent_instance_id) do
    {:via, Registry, {Orquesta.Registry, {__MODULE__, agent_instance_id}}}
  end

  # ---------------------------------------------------------------------------
  # DrainBehaviour callbacks
  # ---------------------------------------------------------------------------

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
  @spec status(Types.outbox_entry_id(), keyword()) ::
          Types.outbox_status() | {:error, :not_found}
  def status(outbox_entry_id, opts) do
    agent_instance_id = Keyword.fetch!(opts, :agent_instance_id)
    GenServer.call(via(agent_instance_id), {:status, outbox_entry_id})
  end

  @impl Orquesta.DrainBehaviour
  @spec reconcile(Types.agent_instance_id(), Types.agent_revision()) :: :ok
  def reconcile(agent_instance_id, committed_revision) do
    # Called by AgentRuntime after do_startup_recovery determines the correct
    # committed_revision. Sets revision and runs the Section 6.2 query.
    GenServer.call(via(agent_instance_id), {:reconcile, committed_revision})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      agent_instance_id: Keyword.fetch!(opts, :agent_instance_id),
      committed_revision: 0,
      outbox: Keyword.fetch!(opts, :outbox),
      codec: Keyword.fetch!(opts, :codec),
      task_supervisor: nil
    }

    {:ok, state, {:continue, :start_task_supervisor}}
  end

  @impl GenServer
  def handle_continue(:start_task_supervisor, state) do
    {:ok, task_sup} = Task.Supervisor.start_link()
    # Do NOT reconcile here — committed_revision is not yet known.
    # AgentRuntime calls reconcile/2 after startup recovery completes.
    {:noreply, %{state | task_supervisor: task_sup}}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task crashed — outbox entry remains :running.
    # Next reconcile/2 call will reset and resubmit.
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:reconcile, committed_revision}, _from, state) do
    # Section 6.2: update revision then reconcile interrupted :running entries
    new_state = %{state | committed_revision: committed_revision}
    :ok = do_reconcile(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:submit, outbox_entry_id}, _from, state) do
    %{outbox: outbox, codec: codec, task_supervisor: task_sup} = state

    result =
      case outbox.get_entry(outbox_entry_id) do
        {:ok, entry} ->
          if OutboxEntry.terminal?(entry) do
            :ok
          else
            # Transition to :running atomically with task acquisition (Section 6.3)
            case outbox.transition(outbox_entry_id, :running) do
              :ok ->
                Task.Supervisor.start_child(task_sup, fn ->
                  execute_directive(entry, outbox, codec)
                end)

                :ok

              {:error, :terminal} ->
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

  def handle_call({:cancel, outbox_entry_id}, _from, %{outbox: outbox} = state) do
    result =
      case outbox.transition(outbox_entry_id, :cancelled) do
        :ok              -> :ok
        {:error, :terminal}   -> :ok
        {:error, :not_found}  -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:status, outbox_entry_id}, _from, %{outbox: outbox} = state) do
    result =
      case outbox.get_entry(outbox_entry_id) do
        {:ok, entry}         -> entry.status
        {:error, :not_found} -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec do_reconcile(%{
          agent_instance_id: Types.agent_instance_id(),
          committed_revision: Types.agent_revision(),
          outbox: module(),
          task_supervisor: pid()
        }) :: :ok
  defp do_reconcile(state) do
    # Section 6.2: reset :running entries at committed_revision and resubmit
    drain_opts = [agent_instance_id: state.agent_instance_id]

    state.outbox.query_by_status_scope_revision(
      :running,
      :agent,
      state.agent_instance_id,
      state.committed_revision
    )
    |> Enum.each(fn entry ->
      :ok = state.outbox.transition(entry.directive_id, :pending)
      submit(entry.directive_id, drain_opts)
    end)

    :ok
  end

  @spec execute_directive(OutboxEntry.t(), module(), module()) :: :ok | {:error, term()}
  defp execute_directive(entry, outbox, codec) do
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

    new_status =
      case result do
        :ok              -> :completed
        {:error, _reason} -> :failed
      end

    _ = outbox.transition(entry.directive_id, new_status)

    result
  end
end
