defmodule Orquesta.Runtime.Execution do
  @moduledoc """
  Default stub implementation of `Orquesta.ExecutionBehaviour`.

  All functions return valid placeholder values and have TODO comments
  referencing the governing spec section. Replace each stub body with the
  real implementation; the @spec and callback contract remain unchanged.

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
    # Section 5.4 — Startup Recovery
    # Step 1: Load latest snapshot
    snapshot_result = data.persistence.load_latest_snapshot(data.agent_instance_id)

    {snapshot_revision, agent} =
      case snapshot_result do
        {:ok, snapshot} ->
          # Decode the state through codec after upcasting
          decoded_agent = data.codec.decode_state(snapshot.encoded_state)
          {snapshot.agent_revision, decoded_agent}

        {:error, :not_found} ->
          # No snapshot - fresh start
          {0, nil}
      end

    # Step 2: Query all outbox entries for this agent
    entries = data.outbox.query_by_scope(:agent, data.agent_instance_id)

    # Determine max outbox revision
    max_outbox_revision =
      case entries do
        [] -> 0
        _ -> Enum.max(Enum.map(entries, & &1.agent_revision))
      end

    cond do
      # Case 1: No recovery needed
      max_outbox_revision <= snapshot_revision ->
        {:ok, %{data | agent: agent, committed_revision: snapshot_revision}}

      # Case 2a: Can resume - need snapshot at max_outbox_revision
      true ->
        case data.persistence.load_snapshot_at_revision(
               data.agent_instance_id,
               max_outbox_revision
             ) do
          {:ok, target_snapshot} ->
            # Decode and resume
            decoded_agent = data.codec.decode_state(target_snapshot.encoded_state)
            entry_ids = Enum.map(entries, & &1.directive_id)

            {:resume,
             %{
               data
               | agent: decoded_agent,
                 committed_revision: max_outbox_revision,
                 outbox_entry_ids: entry_ids
             }}

          {:error, :not_found} ->
            # Case 2b: Divergence - cannot recover
            {:stop, :divergence_error}
        end
    end
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_cmd(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}
  def do_cmd(%RuntimeData{} = data) do
    # Section 7.4 deciding — call agent.cmd/2 and validate phases
    agent = data.agent || data.module.initial_state()

    case data.module.cmd(agent, data.pending_input) do
      {:ok, new_agent, plan} ->
        # Validate directive phases per Section 4.4
        case DirectivePlan.validate_phases(plan) do
          :ok ->
            {:ok, %{data | agent: new_agent, pending_plan: plan}}

          {:error, violations} ->
            {:error, {:invalid_plan, violations}}
        end

      {:error, reason, new_agent, _plan} ->
        # Agent returned error - still update agent state
        {:error, {reason, new_agent}}
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
        :ok -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:pre_directive_failed, directive.directive_id, reason}}}
      end
    end)
  end

  # Build the execute context for DirectiveBehaviour.execute/2
  defp build_execute_context(directive, data) do
    %{
      directive_id: directive.directive_id,
      agent_instance_id: data.agent_instance_id,
      agent_revision: data.pending_revision || data.committed_revision,
      correlation_id: directive.correlation_id,
      causation_id: directive.causation_id,
      trace_context: %{} # TODO: populate from OpenTelemetry context if available
    }
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_checkpoint(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}
  def do_checkpoint(%RuntimeData{} = data) do
    # Section 5.3 — Checkpointing (steps 1-5 in order)

    # Step 1: Assign new agent_revision
    pending_revision = data.committed_revision + 1
    data = %{data | pending_revision: pending_revision}

    # Step 2: Validate directive IDs and assign causal metadata
    plan = data.pending_plan
    effect_directives = plan.effect

    # Check for duplicate directive IDs
    all_ids = DirectivePlan.all_directive_ids(plan)
    unique_ids = Enum.uniq(all_ids)

    if length(all_ids) != length(unique_ids) do
      duplicates = all_ids -- unique_ids
      {:error, {:duplicate_directive_ids, duplicates}}
    else
      # Build outbox entries for effect directives with causal metadata
      now = DateTime.utc_now()

      entries =
        Enum.map(effect_directives, fn directive ->
          # Assign causal metadata to directive
          updated_directive = %{
            directive
            | agent_revision: pending_revision,
              causation_id: data.pending_input.signal_id
          }

          %Orquesta.OutboxEntry{
            directive_id: directive.directive_id,
            scope_type: :agent,
            scope_id: data.agent_instance_id,
            agent_revision: pending_revision,
            encoded_directive: data.codec.encode_directive(updated_directive),
            status: :pending,
            inserted_at: now,
            trace_context: %{}, # TODO: populate from OpenTelemetry
            metadata: %{}
          }
        end)

      entry_ids = Enum.map(entries, & &1.directive_id)

      # Check for cancellation BEFORE step 3 (Section 7.5)
      if data.cancel_requested do
        # Cancelled before outbox write - no state change
        {:error, :cancelled}
      else
        # Step 3: Atomically persist all effect directives to outbox
        case data.outbox.write_entries(entries) do
          :ok ->
            # Check for cancellation AFTER step 3 (Section 7.5)
            if data.cancel_requested do
              # Mark entries as cancelled and abort
              Enum.each(entry_ids, fn id ->
                _ = data.outbox.transition(id, :cancelled)
              end)

              {:error, :cancelled}
            else
              # Step 4: Persist agent snapshot at pending_revision
              snapshot = %Orquesta.AgentSnapshot{
                agent_instance_id: data.agent_instance_id,
                agent_revision: pending_revision,
                agent_module: data.module,
                schema_version: data.module.schema_version(),
                encoded_state: data.codec.encode_state(data.agent),
                inserted_at: DateTime.utc_now()
              }

              case data.persistence.save_snapshot(snapshot) do
                :ok ->
                  # Step 5: Commit the revision
                  {:ok,
                   %{
                     data
                     | committed_revision: pending_revision,
                       outbox_entry_ids: entry_ids
                   }}

                {:error, reason} ->
                  {:error, {:snapshot_failed, reason}}
              end
            end

          {:error, reason} ->
            {:error, {:outbox_write_failed, reason}}
        end
      end
    end
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_submit_effects(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}
  def do_submit_effects(%RuntimeData{} = data) do
    # Section 7.4 submitting_effects — submit each outbox entry to the drain
    Enum.reduce_while(data.outbox_entry_ids, {:ok, data}, fn entry_id, {:ok, acc} ->
      case acc.drain.submit(entry_id, []) do
        :ok -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, {:drain_submit_failed, entry_id, reason}}}
      end
    end)
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_dispatch_post(RuntimeData.t()) :: :ok
  def do_dispatch_post(%RuntimeData{} = data) do
    # Section 7.4 dispatching_post — execute post directives
    # Post failures MUST NOT prevent transition to idle (Section 7.4)
    Enum.each(data.pending_plan.post, fn directive ->
      context = build_execute_context(directive, data)

      try do
        directive.module.execute(directive.args, context)
      rescue
        e ->
          Logger.error("[Orquesta] post directive failed: #{inspect(e)}")
          :telemetry.execute([:orquesta, :directive, :post_failure], %{}, %{directive_id: directive.directive_id})
      end
    end)

    :ok
  end

  @impl Orquesta.ExecutionBehaviour
  @spec do_best_effort_cancel(RuntimeData.t(), CancellationToken.t()) :: :ok
  def do_best_effort_cancel(%RuntimeData{} = data, %CancellationToken{} = token) do
    # Section 7.5 — best-effort cancel via drain
    # Cancel each outbox entry; ignore failures (best-effort)
    Enum.each(data.outbox_entry_ids, fn entry_id ->
      # Check if cancellation is stale before attempting
      case data.outbox.get_entry(entry_id) do
        {:ok, entry} ->
          if not CancellationToken.stale?(token, entry.inserted_at) do
            _ = data.drain.cancel(entry_id, [])
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
    # Section 4.1 — :reject drops the signal and clears pending state
    clear_pending(data)
  end

  def apply_error_policy(%RuntimeData{error_policy: :requeue} = data, _reason) do
    # Section 4.1 — :requeue preserves pending_input for later processing
    # Clear everything except pending_input
    %{
      data
      | pending_plan: nil,
        pending_revision: nil,
        outbox_entry_ids: [],
        cancel_requested: false
    }
  end

  def apply_error_policy(%RuntimeData{error_policy: :escalate} = data, reason) do
    # Section 4.1 — :escalate forwards to dead-letter handler then drops
    # Emit telemetry event for dead-letter handling
    :telemetry.execute([:orquesta, :signal, :escalated], %{}, %{
      agent_instance_id: data.agent_instance_id,
      signal: data.pending_input,
      reason: reason
    })

    # Then clear like :reject
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
      cancel_requested: false
    }
  end
end
