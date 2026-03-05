defmodule Orquesta.CancellationToken do
  @moduledoc """
  A request to cancel a directive or all directives at a given revision.

  A cancellation token is stale and MUST be rejected if:
    `requested_at < directive.inserted_at`

  Cancellation prevents execution. For reversing already-executed effects,
  see `PlanMeta.compensators`.
  """

  alias Orquesta.Types

  @type target :: {:directive, Types.directive_id()} | {:revision, Types.agent_revision()}

  @type t :: %__MODULE__{
          agent_instance_id: Types.agent_instance_id(),
          target: target(),
          correlation_id: Types.correlation_id(),
          reason: term(),
          requested_at: DateTime.t()
        }

  @enforce_keys [:agent_instance_id, :target, :correlation_id, :requested_at]

  defstruct [
    :agent_instance_id,
    :target,
    :correlation_id,
    :reason,
    :requested_at
  ]

  @doc """
  Returns true if the token is stale relative to the given inserted_at timestamp.
  Stale cancellations MUST be rejected.
  """
  @spec stale?(t(), DateTime.t()) :: boolean()
  def stale?(%__MODULE__{requested_at: requested_at}, inserted_at) do
    DateTime.compare(requested_at, inserted_at) == :lt
  end
end
