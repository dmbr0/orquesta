defmodule Orquesta.OutboxEntry do
  @moduledoc """
  A persisted record representing a single effect directive awaiting execution.

  Outbox entries are written atomically before any effect execution begins.
  This is the foundation of the runtime's durability guarantee: no effect
  executes without a durable outbox record.

  The drain implementation MUST read directive content from this struct
  rather than accepting it directly from the runtime.

  Terminal states (`completed`, `cancelled`, `compensated`) MUST NOT
  transition to any other state.
  """

  alias Orquesta.Types

  @type t :: %__MODULE__{
          directive_id: Types.directive_id(),
          scope_type: Types.scope_type(),
          scope_id: Types.scope_id(),
          agent_revision: Types.agent_revision(),
          encoded_directive: term(),
          status: Types.outbox_status(),
          inserted_at: DateTime.t(),
          trace_context: Types.trace_context(),
          metadata: map()
        }

  @enforce_keys [
    :directive_id,
    :scope_type,
    :scope_id,
    :agent_revision,
    :encoded_directive,
    :inserted_at
  ]

  defstruct [
    :directive_id,
    :scope_type,
    :scope_id,
    :agent_revision,
    :encoded_directive,
    :inserted_at,
    status: :pending,
    trace_context: %{},
    metadata: %{}
  ]

  @terminal_states [:completed, :cancelled, :compensated]

  @doc "Returns true if the entry is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in @terminal_states
  end

  @doc "Returns the list of terminal status values."
  @spec terminal_states() :: [Types.terminal_status()]
  def terminal_states, do: @terminal_states

  @doc """
  Returns :ok if transitioning from current status to new_status is valid,
  or {:error, :terminal} if the current status is terminal.
  """
  @spec validate_transition(t(), Types.outbox_status()) :: :ok | {:error, :terminal}
  def validate_transition(%__MODULE__{} = entry, _new_status) do
    if terminal?(entry) do
      {:error, :terminal}
    else
      :ok
    end
  end
end
