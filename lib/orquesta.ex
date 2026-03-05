defmodule Orquesta do
  @moduledoc """
  Orquesta — a deterministic, resumable agent runtime.

  Orquesta implements the Agent Runtime Specification v1. It provides:

  - Deterministic decision execution via pure `cmd/2` agent callbacks
  - Durable side-effect orchestration via a persisted outbox
  - Resumable execution after crashes via checkpoint + recovery
  - Observable execution with traceable causality (telemetry + OTel)
  - Safe coordination across agents via fan-out/gather primitives

  ## Quick start

      # Define your agent module
      defmodule MyAgent do
        @behaviour Orquesta.AgentBehaviour

        defstruct [:count]

        def initial_state, do: %__MODULE__{count: 0}
        def schema_version, do: 1
        def error_policy, do: :reject

        def cmd(%__MODULE__{count: n} = agent, _signal) do
          {:ok, %{agent | count: n + 1}, Orquesta.DirectivePlan.empty()}
        end
      end

      # Start a runtime instance
      {:ok, _pid} = Orquesta.Runtime.RuntimeSupervisor.start_link(
        module: MyAgent,
        agent_instance_id: "my-agent-1",
        drain: Orquesta.Runtime.InternalDrain,
        outbox: Orquesta.Adapters.InMemoryOutbox,
        persistence: Orquesta.Adapters.InMemoryPersistence,
        codec: MyApp.Codec
      )

  ## Architecture

  See `Orquesta.Runtime.AgentRuntime` for the FSM implementation.
  See `Orquesta.AgentBehaviour` for the agent contract.
  See `Orquesta.DrainBehaviour` for the effect execution contract.
  """
end
