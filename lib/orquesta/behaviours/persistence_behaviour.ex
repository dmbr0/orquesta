defmodule Orquesta.PersistenceBehaviour do
  @moduledoc """
  Snapshot storage and schema upcasting seam.

  Snapshots are written during checkpointing (after outbox entries) and
  read during startup recovery. The persistence layer is also responsible
  for upcasting stored state through sequential schema version migrations
  before the codec decodes it.

  Upcasting rules (Section 5.2):
  - Migrations are sequential: v1 → v2 → v3 → v4
  - Direct version jumps are prohibited
  - Each upcast step MUST be deterministic and side-effect free
  """

  alias Orquesta.AgentSnapshot
  alias Orquesta.Types

  @doc "Persists a snapshot. Overwrites any existing snapshot at the same revision."
  @callback save_snapshot(snapshot :: AgentSnapshot.t()) :: :ok | {:error, reason :: term()}

  @doc """
  Loads the latest snapshot for the given agent instance.

  Returns `{:error, :not_found}` for new agents with no history.
  """
  @callback load_latest_snapshot(agent_instance_id :: Types.agent_instance_id()) ::
              {:ok, AgentSnapshot.t()} | {:error, :not_found}

  @doc """
  Loads the snapshot at a specific revision.

  Used during Case 2a recovery when `max_outbox_revision > snapshot_revision`.
  Returns `{:error, :not_found}` if no snapshot exists at that revision,
  which triggers the unrecoverable divergence path.
  """
  @callback load_snapshot_at_revision(
              agent_instance_id :: Types.agent_instance_id(),
              revision :: Types.agent_revision()
            ) :: {:ok, AgentSnapshot.t()} | {:error, :not_found}

  @doc """
  Upcasts encoded state from `from_version` to `to_version` sequentially.

  Migrations must be applied one version at a time. Direct jumps are
  prohibited. Returns `{:error, :no_migration}` if a required migration
  step is not implemented.
  """
  @callback upcast(
              encoded :: term(),
              from_version :: Types.schema_version(),
              to_version :: Types.schema_version()
            ) :: {:ok, term()} | {:error, :no_migration | term()}
end
