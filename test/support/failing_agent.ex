defmodule Orquesta.Test.FailingAgent do
  @moduledoc false

  @behaviour Orquesta.AgentBehaviour

  alias Orquesta.DirectivePlan

  defstruct []

  @impl Orquesta.AgentBehaviour
  def initial_state, do: %__MODULE__{}

  @impl Orquesta.AgentBehaviour
  def schema_version, do: 1

  @impl Orquesta.AgentBehaviour
  def error_policy, do: :reject

  @impl Orquesta.AgentBehaviour
  def cmd(%__MODULE__{} = agent, _signal) do
    # AgentBehaviour requires {:error, reason, new_agent, plan} — 4-tuple.
    {:error, :cmd_always_fails, agent, Orquesta.DirectivePlan.empty()}
  end
end
