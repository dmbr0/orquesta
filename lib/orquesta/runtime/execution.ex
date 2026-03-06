defmodule Orquesta.Runtime.Execution do
  @moduledoc """
  Default implementation of `Orquesta.ExecutionBehaviour`.

  All execution steps are implemented here and dispatched from `AgentRuntime`
  via dynamic dispatch through `data.execution`. See `ExecutionBehaviour` for
  the rationale.

  This module is the default value of `RuntimeData.execution`. Tests may
  substitute a different implementation via `AgentRuntime` opts.
  """

  @behaviour Orquesta.ExecutionBehaviour

  alias Orquesta.Runtime.RuntimeData
  alias Orquesta.CancellationToken
  alias Orquesta.DirectivePlan

  require Logger

  # ---------------------------------------------------------------------------
  # ExecutionBehaviour callbacks
  # ---------------------------------------------------------------------------

  @impl Orquesta.ExecutionBehaviour
  @spec do_startup_recovery(RuntimeData.t()) ::
          {:ok, RuntimeData.t()}
          | {:resume, RuntimeData.t()}
          | {:stop, term()}
  def do_startup_recovery(%RuntimeData{} = data) do
    current_schema_version = data.module.schema_version()

    {snapshot_revision, agent} = load_agent_snapshot(data, current_schema_version)
    pending_entries = fetch_pending_entries(data)
    max_rev = max_pending_revision(pending_entries)

    if pending_entries == [] do
      recover_clean(data, snapshot_revision, agent)
    else
      recover_with_pending(data, current_schema_version, pending_entries, max_rev)
    end
  end

  @spec load_agent_snapshot(RuntimeData.t(), non_neg_integer()) ::
          {non_neg_integer(), term() | nil}
  defp load_agent_snapshot(data, current_schema_version) do
    case data.persistence.load_latest_snapshot(data.agent_instance_id) do
      {:ok, snapshot} ->
        {:ok, upcasted} =
          data.persistence.upcast(
            snapshot.encoded_state,
            snapshot.schema_version,
            current_schema_version
          )

        {snapshot.agent_revision, data.codec.decode_state(upcasted)}

      {:error, :not_found} ->
        {0, nil}
    end
  end

  @spec fetch_pending_entries(RuntimeData.t()) :: [Orquesta.OutboxEntry.t()]
  defp fetch_pending_entries(data) do
    data.outbox.query_by_scope(:agent, data.agent_instance_id)
    |> Enum.reject(&Orquesta.OutboxEntry.terminal?/1)
  end

  @spec max_pending_revision([Orquesta.OutboxEntry.t()]) :: non_neg_integer()
  defp max_pending_revision([]), do: 0
  defp max_pending_revision(entries) do
    entries |> Enum.map(& &1.agent_revision) |> Enum.max()
  end

  @spec recover_clean(RuntimeData.t(), non_neg_integer(), term() | nil) ::
          {:ok, RuntimeData.t()}
  defp recover_clean(data, snapshot_revision, agent) do
    committed_revision = snapshot_revision
    new_data = %{data | agent: agent, committed_revision: committed_revision}
    :ok = new_data.drain.reconcile(new_data.agent_instance_id, committed_revision)
    {:ok, new_data}
  end

  @spec recover_with_pending(
          RuntimeData.t(),
          non_neg_integer(),
          [Orquesta.OutboxEntry.t()],
          non_neg_integer()
        ) :: {:resume, RuntimeData.t()} | {:stop, term()}
  defp recover_with_pending(data, schema_ver, pending_entries, max_rev) do
    case data.persistence.load_snapshot_at_revision(data.agent_instance_id, max_rev) do
      {:ok, snapshot} ->
        recover_resumable(data, schema_ver, pending_entries, max_rev, snapshot)

      {:error, :not_found} ->
        {:stop, :divergence_error}
    end
  end

  @spec recover_resumable(
          RuntimeData.t(),
          non_neg_integer(),
          [Orquesta.OutboxEntry.t()],
          non_neg_integer(),
          Orquesta.AgentSnapshot.t()
        ) :: {:resume, RuntimeData.t()}
  defp recover_resumable(data, schema_ver, pending_entries, max_rev, snapshot) do
    {:ok, upcasted} =
      data.persistence.upcast(
        snapshot.encoded_state,
        snapshot.schema_version,
        schema_ver
      )

    decoded_agent = data.codec.decode_state(upcasted)

    entry_ids =
      pending_entries
      |> Enum.filter(&(&1.agent_revision == max_rev))
      |> Enum.map(& &1.directive_id)

    committed_revision = max_rev

    new_data = %{data | agent: decoded_agent, committed_revision: committed_revision, outbox_entry_ids: entry_ids}
    :ok = new_data.drain.reconcile(new_data.agent_instance_id, committed_revision)
    {:resume, new_data}
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_cmd(RuntimeData.t()) ::
          {:ok, RuntimeData.t()} | {:error, term(), RuntimeData.t()}
  def do_cmd(%RuntimeData{} = data) do
    # Section 7.4 deciding — call agent.cmd/2 and validate phases
    agent = data.agent || data.module.initial_state()

    case data.module.cmd(agent, data.pending_input) do
      {:ok, new_agent, plan} ->
        case DirectivePlan.validate_phases(plan) do
          :ok ->
            {:ok, %{data | agent: new_agent, pending_plan: plan}}

          {:error, violations} ->
            # Return updated agent state even on plan validation failure
            {:error, {:invalid_plan, violations}, %{data | agent: new_agent}}
        end

      {:error, reason, new_agent, _plan} ->
        # Agent returned error — preserve updated agent state in the error tuple.
        # AgentRuntime passes this new_data to apply_error_policy so the state
        # is never silently discarded.
        {:error, {:agent_error, reason}, %{data | agent: new_agent}}
    end
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_dispatch_pre(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}
  def do_dispatch_pre(%RuntimeData{} = data) do
    # Section 7.4 dispatching_pre — execute pre directives synchronously
    # No I/O permitted; first failure halts
    Enum.reduce_while(data.pending_plan.pre, {:ok, data}, fn directive, {:ok, acc} ->
      context = build_execute_context(directive, acc)

      case directive.module.execute(directive.args, context) do
        :ok ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, {:pre_directive_failed, directive.directive_id, reason}}}
      end
    end)
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_checkpoint(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}
  def do_checkpoint(%RuntimeData{} = data) do
    pending_revision = data.committed_revision + 1
    data = %{data | pending_revision: pending_revision}

    case check_unique_ids(data.pending_plan) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        entries = build_outbox_entries(data, pending_revision)
        entry_ids = Enum.map(entries, & &1.directive_id)

        if data.cancel_requested do
          {:error, :cancelled}
        else
          checkpoint_write(data, entries, entry_ids, pending_revision)
        end
    end
  end

  @spec check_unique_ids(DirectivePlan.t()) :: :ok | {:error, term()}
  defp check_unique_ids(plan) do
    all_ids = DirectivePlan.all_directive_ids(plan)
    unique_ids = Enum.uniq(all_ids)

    if length(all_ids) != length(unique_ids) do
      duplicates = all_ids -- unique_ids
      {:error, {:duplicate_directive_ids, duplicates}}
    else
      :ok
    end
  end

  @spec build_outbox_entries(RuntimeData.t(), non_neg_integer()) ::
          [Orquesta.OutboxEntry.t()]
  defp build_outbox_entries(data, pending_revision) do
    now = DateTime.utc_now()

    Enum.map(data.pending_plan.effect, fn directive ->
      updated_directive = %{directive | agent_revision: pending_revision, causation_id: data.pending_input.signal_id}

      %Orquesta.OutboxEntry{
        directive_id: directive.directive_id,
        scope_type: :agent,
        scope_id: data.agent_instance_id,
        agent_revision: pending_revision,
        encoded_directive: data.codec.encode_directive(updated_directive),
        status: :pending,
        inserted_at: now,
        trace_context: %{},
        metadata: %{}
      }
    end)
  end

  @spec checkpoint_write(
          RuntimeData.t(),
          [Orquesta.OutboxEntry.t()],
          [String.t()],
          non_neg_integer()
        ) :: {:ok, RuntimeData.t()} | {:error, term()}
  defp checkpoint_write(data, entries, entry_ids, pending_revision) do
    case data.outbox.write_entries(entries) do
      :ok ->
        checkpoint_post_write(data, entry_ids, pending_revision)

      {:error, reason} ->
        {:error, {:outbox_write_failed, reason}}
    end
  end

  @spec checkpoint_post_write(
          RuntimeData.t(),
          [String.t()],
          non_neg_integer()
        ) :: {:ok, RuntimeData.t()} | {:error, term()}
  defp checkpoint_post_write(data, entry_ids, pending_revision) do
    if data.cancel_requested do
      Enum.each(entry_ids, fn id ->
        _ = data.outbox.transition(id, :cancelled)
      end)

      {:error, :cancelled}
    else
      snapshot = build_snapshot(data, pending_revision)

      case data.persistence.save_snapshot(snapshot) do
        :ok ->
          {:ok, %{data | committed_revision: pending_revision, outbox_entry_ids: entry_ids}}

        {:error, reason} ->
          {:error, {:snapshot_failed, reason}}
      end
    end
  end

  @spec build_snapshot(RuntimeData.t(), non_neg_integer()) :: Orquesta.AgentSnapshot.t()
  defp build_snapshot(data, pending_revision) do
    %Orquesta.AgentSnapshot{
      agent_instance_id: data.agent_instance_id,
      agent_revision: pending_revision,
      agent_module: data.module,
      schema_version: data.module.schema_version(),
      encoded_state: data.codec.encode_state(data.agent),
      inserted_at: DateTime.utc_now()
    }
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_submit_effects(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}
  def do_submit_effects(%RuntimeData{} = data) do
    # Section 7.4 submitting_effects — submit each outbox entry to the drain.
    # Section 7.5: if cancel_requested was set after the outbox write, mark all
    # pending entries :cancelled and skip drain.submit.
    if data.cancel_requested do
      Enum.each(data.outbox_entry_ids, fn entry_id ->
        _ = data.outbox.transition(entry_id, :cancelled)
      end)

      {:ok, data}
    else
      drain_opts = [agent_instance_id: data.agent_instance_id]

      Enum.reduce_while(data.outbox_entry_ids, {:ok, data}, fn entry_id, {:ok, acc} ->
        case acc.drain.submit(entry_id, drain_opts) do
          :ok              -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, {:drain_submit_failed, entry_id, reason}}}
        end
      end)
    end
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_dispatch_post(RuntimeData.t()) :: :ok
  # Guard against nil pending_plan — can occur after a recovery resume where
  # the plan is not reconstructed from outbox entries (outbox_entry_ids only).
  def do_dispatch_post(%RuntimeData{pending_plan: nil}), do: :ok

  def do_dispatch_post(%RuntimeData{} = data) do
    # Section 7.4 dispatching_post — post failures MUST NOT prevent idle transition
    Enum.each(data.pending_plan.post, fn directive ->
      context = build_execute_context(directive, data)

      try do
        directive.module.execute(directive.args, context)
      rescue
        e ->
          Logger.error("[Orquesta] post directive failed: #{inspect(e)}")

          :telemetry.execute(
            [:orquesta, :directive, :post_failure],
            %{},
            %{directive_id: directive.directive_id}
          )
      end
    end)

    :ok
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_best_effort_cancel(RuntimeData.t(), CancellationToken.t()) :: :ok
  def do_best_effort_cancel(%RuntimeData{} = data, %CancellationToken{} = token) do
    # Section 7.5 — best-effort, errors ignored
    drain_opts = [agent_instance_id: data.agent_instance_id]

    Enum.each(data.outbox_entry_ids, fn entry_id ->
      case data.outbox.get_entry(entry_id) do
        {:ok, entry} ->
          unless CancellationToken.stale?(token, entry.inserted_at) do
            _ = data.drain.cancel(entry_id, drain_opts)
          end

        {:error, :not_found} ->
          :ok
      end
    end)

    :ok
  end

  @impl Orquesta.ExecutionBehaviour
  @spec apply_error_policy(RuntimeData.t(), term()) :: RuntimeData.t()
  def apply_error_policy(%RuntimeData{error_policy: :reject} = data, _reason) do
    # Section 4.1 — drop signal, clear all pending state
    clear_pending(data)
  end

  def apply_error_policy(%RuntimeData{error_policy: :requeue} = data, _reason) do
    # Section 4.1 — preserve pending_input for later reprocessing
    %{data | pending_plan: nil, pending_revision: nil, outbox_entry_ids: [], cancel_requested: false}
  end

  def apply_error_policy(%RuntimeData{error_policy: :escalate} = data, reason) do
    # Section 4.1 — forward to dead-letter handler, then drop
    :telemetry.execute([:orquesta, :signal, :escalated], %{}, %{
      agent_instance_id: data.agent_instance_id,
      signal: data.pending_input,
      reason: reason
    })

    clear_pending(data)
  end

  @impl Orquesta.ExecutionBehaviour
  @spec clear_pending(RuntimeData.t()) :: RuntimeData.t()
  def clear_pending(%RuntimeData{} = data) do
    %{data |
      pending_input: nil,
      pending_plan: nil,
      pending_revision: nil,
      outbox_entry_ids: [],
      cancel_requested: false,
      pending_caller: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec build_execute_context(Orquesta.Directive.t(), RuntimeData.t()) ::
          Orquesta.DirectiveBehaviour.execute_context()
  defp build_execute_context(directive, data) do
    %{
      directive_id: directive.directive_id,
      agent_instance_id: data.agent_instance_id,
      agent_revision: data.pending_revision || data.committed_revision,
      correlation_id: directive.correlation_id,
      causation_id: directive.causation_id,
      trace_context: %{}
    }
  end
end
