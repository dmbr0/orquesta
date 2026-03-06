defmodule Orquesta.Test.EffectAgent do
  @moduledoc false

  @behaviour Orquesta.AgentBehaviour

  alias Orquesta.Directive
  alias Orquesta.DirectivePlan

  defstruct count: 0

  @impl Orquesta.AgentBehaviour
  def initial_state, do: %__MODULE__{}

  @impl Orquesta.AgentBehaviour
  def schema_version, do: 1

  @impl Orquesta.AgentBehaviour
  def error_policy, do: :reject

  @impl Orquesta.AgentBehaviour
  def cmd(%__MODULE__{count: n} = agent, signal) do
    directive = %Directive{
      directive_id: "noop-#{signal.correlation_id}-#{n + 1}",
      module: Orquesta.Test.NoopDirective,
      args: %{count: n + 1},
      correlation_id: signal.correlation_id
    }

    plan = %DirectivePlan{effect: [directive]}
    {:ok, %{agent | count: n + 1}, plan}
  end
end
