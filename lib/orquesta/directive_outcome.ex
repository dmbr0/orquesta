defmodule Orquesta.DirectiveOutcome do
  @moduledoc """
  A signal emitted when a directive reaches a terminal state.

  Whether outcome signals are emitted is controlled by `PlanMeta.outcome_signals`:
  - `:none`     — no outcome signals emitted (default)
  - `:failures` — emitted only for `:failed` and `:cancelled` outcomes
  - `:all`      — emitted for all terminal outcomes

  When emitted, these signals enter the agent's runtime inbox and are processed
  as normal inputs through the FSM. The agent remains purely signal-driven.
  """

  alias Orquesta.Types

  @type t :: %__MODULE__{
          signal_id: Types.signal_id(),
          agent_instance_id: Types.agent_instance_id(),
          directive_id: Types.directive_id(),
          outcome: Types.directive_outcome(),
          reason: term(),
          correlation_id: Types.correlation_id(),
          causation_id: Types.causation_id()
        }

  @enforce_keys [
    :signal_id,
    :agent_instance_id,
    :directive_id,
    :outcome,
    :correlation_id,
    :causation_id
  ]

  defstruct [
    :signal_id,
    :agent_instance_id,
    :directive_id,
    :outcome,
    :reason,
    :correlation_id,
    :causation_id
  ]
end
