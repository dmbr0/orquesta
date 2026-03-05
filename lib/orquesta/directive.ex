defmodule Orquesta.Directive do
  @moduledoc """
  A directive is an effect intent produced during a decision cycle.

  It wraps a directive module (which implements `Orquesta.DirectiveBehaviour`)
  along with arguments and causal metadata. Directive IDs are assigned by the
  agent at plan construction time — before checkpointing — so that
  `PlanMeta.compensators` can reference them by ID.

  The runtime validates that each directive's module declares the correct
  phase via `Orquesta.DirectiveBehaviour.phase/0` before checkpointing begins.
  """

  alias Orquesta.Types

  @type t :: %__MODULE__{
          directive_id: Types.directive_id(),
          module: module(),
          args: term(),
          correlation_id: Types.correlation_id(),
          causation_id: Types.causation_id() | nil,
          agent_revision: Types.agent_revision() | nil
        }

  @enforce_keys [:directive_id, :module, :correlation_id]
  defstruct [
    :directive_id,
    :module,
    :args,
    :correlation_id,
    :causation_id,
    :agent_revision
  ]

  @doc "Returns the declared phase of this directive by calling its module callback."
  @spec phase(t()) :: Types.phase()
  def phase(%__MODULE__{module: mod}) do
    mod.phase()
  end

  @doc "Returns true if the directive's module declares the expected phase."
  @spec valid_phase?(t(), Types.phase()) :: boolean()
  def valid_phase?(%__MODULE__{} = directive, expected_phase) do
    phase(directive) == expected_phase
  end
end
