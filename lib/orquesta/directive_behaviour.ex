defmodule Orquesta.DirectiveBehaviour do
  @moduledoc """
  Behaviour that every directive module must implement.

  Each directive module declares its phase affinity and provides an execute
  callback. The runtime validates phase placement before checkpointing.

  Compensators are declared at the plan level via `PlanMeta.compensators`,
  not per-directive-module, to avoid the chicken-and-egg problem with
  directive IDs being assigned at plan construction time.
  """

  alias Orquesta.Types

  @doc """
  Declares which phase this directive belongs to.

  The runtime validates that directives appear only in their declared phase.
  Invalid plans are rejected before checkpointing.
  """
  @callback phase() :: Types.phase()

  @doc """
  Executes the directive with the given arguments and context.

  Effects MUST be idempotent with respect to the directive_id provided
  in context. Executing the same directive_id twice MUST produce the same
  observable result as executing it once.
  """
  @callback execute(args :: term(), context :: execute_context()) ::
              :ok | {:error, reason :: term()}

  @typedoc "Context passed to execute/2 containing causal metadata"
  @type execute_context :: %{
          directive_id: Types.directive_id(),
          agent_instance_id: Types.agent_instance_id(),
          agent_revision: Types.agent_revision(),
          correlation_id: Types.correlation_id(),
          causation_id: Types.causation_id() | nil,
          trace_context: Types.trace_context()
        }
end
