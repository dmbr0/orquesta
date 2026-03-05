defmodule Orquesta.DirectivePlan do
  @moduledoc """
  The output of a single agent decision cycle.

  A plan contains three ordered phases of directives:

  - `pre`    — deterministic runtime work (no I/O, no unmanaged processes)
  - `effect` — external side effects (persisted to outbox before execution)
  - `post`   — replies, signals, logging (not persisted, best-effort)

  Checkpointing occurs between the `pre` and `effect` phases.

  An empty plan (all phases empty) is valid and results in a no-op cycle.
  """

  alias Orquesta.Directive
  alias Orquesta.PlanMeta
  alias Orquesta.Types

  @type phase_violation :: {Types.directive_id(), Types.phase(), Types.phase()}

  @type t :: %__MODULE__{
          pre: [Directive.t()],
          effect: [Directive.t()],
          post: [Directive.t()],
          meta: PlanMeta.t()
        }

  defstruct [
    pre: [],
    effect: [],
    post: [],
    meta: %PlanMeta{}
  ]

  @doc "Returns an empty plan with default metadata."
  @spec empty() :: t()
  def empty do
    %__MODULE__{}
  end

  @doc "Returns all directives across all phases in execution order."
  @spec all_directives(t()) :: [Directive.t()]
  def all_directives(%__MODULE__{pre: pre, effect: effect, post: post}) do
    pre ++ effect ++ post
  end

  @doc "Returns all directive_ids across all phases."
  @spec all_directive_ids(t()) :: [Types.directive_id()]
  def all_directive_ids(%__MODULE__{} = plan) do
    plan
    |> all_directives()
    |> Enum.map(& &1.directive_id)
  end

  @doc """
  Validates that all directives are in their declared phase.
  Returns :ok or {:error, violations} where each violation is
  {directive_id, declared_phase, placed_in_phase}.
  """
  @spec validate_phases(t()) :: :ok | {:error, [phase_violation()]}
  def validate_phases(%__MODULE__{pre: pre, effect: effect, post: post}) do
    violations =
      Enum.flat_map(pre, &check_phase(&1, :pre)) ++
        Enum.flat_map(effect, &check_phase(&1, :effect)) ++
        Enum.flat_map(post, &check_phase(&1, :post))

    case violations do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @spec check_phase(Directive.t(), Types.phase()) :: [phase_violation()]
  defp check_phase(%Directive{} = directive, expected) do
    declared = Directive.phase(directive)

    if declared == expected do
      []
    else
      [{directive.directive_id, declared, expected}]
    end
  end
end
