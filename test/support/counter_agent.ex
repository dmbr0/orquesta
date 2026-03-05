defmodule Orquesta.Test.CounterAgent do
  @moduledoc false

  @behaviour Orquesta.AgentBehaviour

  defstruct count: 0

  @impl Orquesta.AgentBehaviour
  def initial_state, do: %__MODULE__{}

  @impl Orquesta.AgentBehaviour
  def schema_version, do: 1

  @impl Orquesta.AgentBehaviour
  def error_policy, do: :reject

  @impl Orquesta.AgentBehaviour
  def cmd(%__MODULE__{count: n} = agent, _signal) do
    {:ok, %{agent | count: n + 1}, Orquesta.DirectivePlan.empty()}
  end
end
