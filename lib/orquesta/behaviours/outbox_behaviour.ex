defmodule Orquesta.OutboxBehaviour do
  @moduledoc """
  Durable outbox storage seam.

  The outbox is the source of truth for all effect directives. The runtime
  writes entries atomically before submitting to the drain. The drain reads
  content from the outbox rather than receiving it inline.

  Implementations must guarantee that `write_entries/1` is atomic: either
  all entries for a plan are written or none are. Partial writes MUST NOT
  be observable.

  Terminal states MUST NOT be transitioned by `transition/2`. Callers
  should check `OutboxEntry.terminal?/1` before calling.
  """

  alias Orquesta.OutboxEntry
  alias Orquesta.Types

  @doc """
  Atomically persists all outbox entries for a single plan.

  Either all entries are written or none. This is the atomicity guarantee
  from Section 5.3 step 3.
  """
  @callback write_entries(entries :: [OutboxEntry.t()]) :: :ok | {:error, reason :: term()}

  @doc """
  Transitions a single outbox entry to a new status.

  MUST return `{:error, :terminal}` if the current status is terminal.
  MUST NOT allow transition out of terminal states.
  """
  @callback transition(
              outbox_entry_id :: Types.outbox_entry_id(),
              new_status :: Types.outbox_status()
            ) ::
              :ok | {:error, :terminal | :not_found | term()}

  @doc "Fetches a single outbox entry by ID."
  @callback get_entry(outbox_entry_id :: Types.outbox_entry_id()) ::
              {:ok, OutboxEntry.t()} | {:error, :not_found}

  @doc """
  Queries all outbox entries for a given scope.

  Used during startup recovery to detect interrupted checkpoints.
  """
  @callback query_by_scope(scope_type :: Types.scope_type(), scope_id :: Types.scope_id()) ::
              [OutboxEntry.t()]

  @doc """
  Queries entries matching status, scope, and revision.

  Used by internal drain startup reconciliation to find interrupted `:running`
  entries for a specific committed revision.
  """
  @callback query_by_status_scope_revision(
              status :: Types.outbox_status(),
              scope_type :: Types.scope_type(),
              scope_id :: Types.scope_id(),
              agent_revision :: Types.agent_revision()
            ) :: [OutboxEntry.t()]
end
