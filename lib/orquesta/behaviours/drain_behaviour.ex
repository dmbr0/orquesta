defmodule Orquesta.DrainBehaviour do
  @moduledoc """
  The seam between the runtime and effect execution.

  Drain implementations are responsible for executing effect directives.
  They MUST read directive content from the outbox using `outbox_entry_id`
  rather than accepting it directly from the runtime caller.

  ## opts convention

  `submit/2`, `cancel/2`, and `status/2` receive `opts` that always include:

      agent_instance_id: String.t()

  Internal drain implementations use this to route calls to the correct
  per-agent drain process via the registry. External drain implementations
  (Oban, etc.) may use or ignore it as appropriate.

  ## Reconciliation

  `reconcile/2` is called by `AgentRuntime` after startup recovery completes,
  once the correct `committed_revision` is known. Internal drains use this to
  reset `:running` entries that were interrupted by a crash. External drains
  may implement this as a no-op if they handle reconciliation independently.

  Drain implementations MUST NOT retry directives with terminal status
  (`:cancelled`, `:compensated`).
  """

  alias Orquesta.Types

  @doc """
  Submits an outbox entry for execution.

  The drain MUST read the directive content from the outbox using the
  provided `outbox_entry_id`. It MUST NOT accept directive content inline.

  The `:running` outbox transition occurs when execution begins, not
  when `submit/2` is called.

  `opts` MUST include `agent_instance_id:` for routing to the correct
  drain process instance.
  """
  @callback submit(outbox_entry_id :: Types.outbox_entry_id(), opts :: keyword()) ::
              :ok | {:error, reason :: term()}

  @doc """
  Attempts to cancel execution of a submitted directive.

  Cancellation is best-effort once execution has begun. If the directive
  has already reached a terminal state, this MUST return `:ok` (idempotent).

  `opts` MUST include `agent_instance_id:` for routing.
  """
  @callback cancel(outbox_entry_id :: Types.outbox_entry_id(), opts :: keyword()) ::
              :ok | {:error, reason :: term()}

  @doc """
  Returns the current execution status of a submitted directive.

  `opts` MUST include `agent_instance_id:` for routing.
  """
  @callback status(outbox_entry_id :: Types.outbox_entry_id(), opts :: keyword()) ::
              Types.outbox_status() | {:error, :not_found}

  @doc """
  Called by `AgentRuntime` after startup recovery to trigger reconciliation
  with the correct committed revision.

  Internal drains MUST query entries where:
    status == :running AND scope_type == :agent
    AND scope_id == agent_instance_id AND agent_revision == committed_revision

  Reset each to `:pending` and resubmit.

  External drain implementations MAY return `:ok` immediately if they
  handle reconciliation through their own infrastructure.
  """
  @callback reconcile(
              agent_instance_id :: Types.agent_instance_id(),
              committed_revision :: Types.agent_revision()
            ) :: :ok
end
