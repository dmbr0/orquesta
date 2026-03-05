defmodule Orquesta.PlanMeta do
  @moduledoc """
  Metadata attached to a `DirectivePlan`.

  The `compensators` map keys are `directive_id` values assigned by the agent
  at plan construction time (before checkpointing). Each value is the
  compensating directive to execute if the keyed directive requires compensation.

  Compensators MUST NOT themselves have compensators. The runtime enforces this
  by checking that no directive_id appearing as a value in this map also appears
  as a key.
  """

  alias Orquesta.Types
  alias Orquesta.Directive

  @type t :: %__MODULE__{
          compensation_policy: Types.compensation_policy(),
          outcome_signals: Types.outcome_signals_policy(),
          compensators: %{optional(Types.directive_id()) => Directive.t()}
        }

  defstruct [
    compensation_policy: :none,
    outcome_signals: :none,
    compensators: %{}
  ]

  @doc "Returns a PlanMeta with all defaults (no compensation, no outcome signals)."
  @spec default() :: t()
  def default do
    %__MODULE__{}
  end

  @doc """
  Returns true if the compensators map is valid: no directive_id appears
  as both a key and a value's directive_id, preventing recursive compensation.
  """
  @spec valid_compensators?(t()) :: boolean()
  def valid_compensators?(%__MODULE__{compensators: compensators}) do
    compensator_ids =
      compensators
      |> Map.values()
      |> Enum.map(& &1.directive_id)
      |> MapSet.new()

    key_ids = MapSet.new(Map.keys(compensators))

    MapSet.disjoint?(key_ids, compensator_ids)
  end
end
