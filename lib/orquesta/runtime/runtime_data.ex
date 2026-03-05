defmodule Orquesta.Runtime.RuntimeData do
  @moduledoc """
  Internal state of the agent runtime FSM.

  This struct is NEVER stored in the agent struct and NEVER exposed through
  public APIs. It represents volatile runtime context only.

  The `execution` field holds the module implementing `Orquesta.ExecutionBehaviour`.
  It defaults to `Orquesta.Runtime.Execution` and may be overridden in opts
  (e.g., to a test double) when starting `AgentRuntime`.
  """

  alias Orquesta.Types
  alias Orquesta.Signal
  alias Orquesta.DirectivePlan

  @type t :: %__MODULE__{
          # Identity
          agent_instance_id: Types.agent_instance_id(),
          module: module(),
          # Agent state — kept separate from runtime state (Section 7.1)
          agent: struct() | nil,
          # Transient — current decision cycle
          pending_input: Signal.t() | nil,
          pending_plan: DirectivePlan.t() | nil,
          pending_revision: Types.agent_revision() | nil,
          outbox_entry_ids: [Types.outbox_entry_id()],
          cancel_requested: boolean(),
          # Durable
          committed_revision: Types.agent_revision(),
          # Pluggable modules — execution has a default; others required at startup via fetch!
          execution: module(),
          drain: module() | nil,
          outbox: module() | nil,
          persistence: module() | nil,
          codec: module() | nil,
          # Policy
          error_policy: Types.error_policy()
        }

  defstruct [
    :module,
    :agent,
    :pending_input,
    :pending_plan,
    :pending_revision,
    agent_instance_id: "",
    outbox_entry_ids: [],
    cancel_requested: false,
    committed_revision: 0,
    execution: Orquesta.Runtime.Execution,
    drain: nil,
    outbox: nil,
    persistence: nil,
    codec: nil,
    error_policy: :reject
  ]
end
