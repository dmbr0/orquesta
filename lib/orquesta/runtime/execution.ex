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
    # Section 5.4 — Startup Recovery
    current_schema_version = data.module.schema_version()

    # Step 1: Load latest snapshot
    {snapshot_revision, agent} =
      case data.persistence.load_latest_snapshot(data.agent_instance_id) do
        {:ok, snapshot} ->
          # Section 5.2: upcast before decoding
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

    # Step 2: Query all outbox entries for this agent; split into non-terminal
    # (still require action) and terminal (already done, ignore).
    all_entries = data.outbox.query_by_scope(:agent, data.agent_instance_id)
    pending_entries = Enum.reject(all_entries, &Orquesta.OutboxEntry.terminal?/1)

    # Determine max revision among non-terminal entries only.
    max_pending_revision =
      case pending_entries do
        [] -> 0
        _  -> pending_entries |> Enum.map(& &1.agent_revision) |> Enum.max()
      end

    cond do
      # Case 1: no non-terminal entries — clean restart, no resubmission needed.
      # This is correct even when max_pending_revision == snapshot_revision
      # (e.g. all entries at that revision are already terminal).
      pending_entries == [] ->
        committed_revision = snapshot_revision
        new_data = %{data | agent: agent, committed_revision: committed_revision}
        # Notify drain of the correct revision so it can reconcile `:running` entries
        :ok = new_data.drain.reconcile(new_data.agent_instance_id, committed_revision)
        {:ok, new_data}

      # Case 2: non-terminal entries exist — determine 2a vs 2b by looking for
      # a snapshot at max_pending_revision.
      true ->
        case data.persistence.load_snapshot_at_revision(
               data.agent_instance_id,
               max_pending_revision
             ) do
          {:ok, target_snapshot} ->
            # Case 2a: resumable — snapshot exists at the pending revision.
            {:ok, upcasted} =
              data.persistence.upcast(
                target_snapshot.encoded_state,
                target_snapshot.schema_version,
                current_schema_version
              )

            decoded_agent = data.codec.decode_state(upcasted)

            # Only resubmit entries at max_pending_revision (not stale revisions).
            entry_ids =
              pending_entries
              |> Enum.filter(&(&1.agent_revision == max_pending_revision))
              |> Enum.map(& &1.directive_id)

            committed_revision = max_pending_revision

            new_data = %{
              data
              | agent: decoded_agent,
                committed_revision: committed_revision,
                outbox_entry_ids: entry_ids
            }

            # Notify drain — it reconciles `:running` entries before we resubmit
            :ok = new_data.drain.reconcile(new_data.agent_instance_id, committed_revision)
            {:resume, new_data}

          {:error, :not_found} ->
            # Case 2b: divergence — no snapshot at max_pending_revision.
            # This means outbox is ahead of every known snapshot; state is corrupt.
            {:stop, :divergence_error}
        end
    end
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
    # Section 5.3 — five-step checkpoint protocol

    # Step 1: assign new revision
    pending_revision = data.committed_revision + 1
    data = %{data | pending_revision: pending_revision}

    # Step 2: validate directive IDs are present and unique
    plan = data.pending_plan
    all_ids = DirectivePlan.all_directive_ids(plan)
    unique_ids = Enum.uniq(all_ids)

    if length(all_ids) != length(unique_ids) do
      duplicates = all_ids -- unique_ids
      {:error, {:duplicate_directive_ids, duplicates}}
    else
      now = DateTime.utc_now()

      # Build outbox entries with causal metadata assigned (step 2 continued)
      entries =
        Enum.map(plan.effect, fn directive ->
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
            trace_context: %{},
            metadata: %{}
          }
        end)

      entry_ids = Enum.map(entries, & &1.directive_id)

      # Check cancellation BEFORE step 3 (Section 7.5)
      if data.cancel_requested do
        {:error, :cancelled}
      else
        # Step 3: atomically persist all effect directives to the outbox
        case data.outbox.write_entries(entries) do
          :ok ->
            # Check cancellation AFTER step 3 (Section 7.5)
            if data.cancel_requested do
              Enum.each(entry_ids, fn id ->
                _ = data.outbox.transition(id, :cancelled)
              end)

              {:error, :cancelled}
            else
              # Step 4: persist agent snapshot at pending_revision
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
                  # Step 5: commit the revision
                  {:ok, %{data | committed_revision: pending_revision, outbox_entry_ids: entry_ids}}

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
