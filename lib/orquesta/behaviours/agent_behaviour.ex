defmodule Orquesta.AgentBehaviour do
  @moduledoc """
  Behaviour that every agent module must implement.

  Agents are pure state machines. The `cmd/2` callback is the only place
  where agent logic runs. It receives the current agent struct and an
  immutable input signal, and returns either a new agent struct + plan,
  or an error with partial plan metadata.

  `cmd/2` MUST be free of side effects. All effects are expressed as
  directives in the returned `DirectivePlan`.
  """

  alias Orquesta.Signal
  alias Orquesta.DirectivePlan

  @doc """
  Pure decision function. Receives the current agent state and an input signal.
  Returns the new agent state and a plan describing what should happen next.

  This function MUST NOT perform I/O, start processes, or mutate external state.
  """
  @callback cmd(agent :: struct(), signal :: Signal.t()) ::
              {:ok, new_agent :: struct(), DirectivePlan.t()}
              | {:error, reason :: term(), new_agent :: struct(), DirectivePlan.t()}

  @doc "Returns the initial agent struct for a newly started runtime instance."
  @callback initial_state() :: struct()

  @doc """
  Returns the error policy for this agent.

  Controls what happens to the input signal when a decision cycle fails
  (invalid plan, pre directive failure, or checkpointing failure):
  - `:reject`   — signal is dropped and an error is emitted (default)
  - `:requeue`  — signal is returned for later reprocessing
  - `:escalate` — signal is forwarded to a dead-letter handler
  """
  @callback error_policy() :: Orquesta.Types.error_policy()

  @doc "Returns the current schema version for state serialization."
  @callback schema_version() :: Orquesta.Types.schema_version()
end
