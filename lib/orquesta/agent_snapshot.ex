defmodule Orquesta.AgentSnapshot do
  @moduledoc """
  A committed snapshot of agent state at a specific revision.

  Snapshots are written during checkpointing (step 4 of Section 5.3) after
  outbox entries have been persisted. This ordering ensures that a snapshot
  at revision N implies all outbox entries at revision N are also durable.

  The `schema_version` field drives upcasting (Section 5.2). Sequential
  migration through schema versions is required; version jumps are prohibited.
  """

  alias Orquesta.Types

  @type t :: %__MODULE__{
          agent_instance_id: Types.agent_instance_id(),
          agent_revision: Types.agent_revision(),
          agent_module: module(),
          schema_version: Types.schema_version(),
          encoded_state: term(),
          inserted_at: DateTime.t()
        }

  @enforce_keys [
    :agent_instance_id,
    :agent_revision,
    :agent_module,
    :schema_version,
    :encoded_state,
    :inserted_at
  ]

  defstruct [
    :agent_instance_id,
    :agent_revision,
    :agent_module,
    :schema_version,
    :encoded_state,
    :inserted_at
  ]
end
