defmodule Orquesta.Types do
  @moduledoc """
  Shared type definitions for the Orquesta agent runtime.

  All identity, causality, and status types are defined here and
  referenced by every other module in the runtime.
  """

  @typedoc "Unique identifier for a signal"
  @type signal_id :: String.t()

  @typedoc "Unique identifier for a directive, assigned by the agent at plan construction time"
  @type directive_id :: String.t()

  @typedoc "Unique identifier for an outbox entry (same as directive_id for agent-scoped entries)"
  @type outbox_entry_id :: String.t()

  @typedoc "Unique identifier for a runtime agent instance"
  @type agent_instance_id :: String.t()

  @typedoc "Unique identifier for a coordinator process"
  @type coordinator_instance_id :: String.t()

  @typedoc "Monotonically increasing revision number, incremented only during checkpointing"
  @type agent_revision :: non_neg_integer()

  @typedoc "Propagates unchanged through all related operations in a request chain"
  @type correlation_id :: String.t()

  @typedoc "References the signal or directive that triggered an operation"
  @type causation_id :: String.t()

  @typedoc "Schema version for state evolution and upcasting"
  @type schema_version :: non_neg_integer()

  @typedoc "Identifies whether an outbox entry belongs to an agent or coordinator"
  @type scope_type :: :agent | :coordinator

  @typedoc "The instance ID of the scope owner (agent_instance_id or coordinator_instance_id)"
  @type scope_id :: String.t()

  @typedoc "All possible outbox entry states"
  @type outbox_status ::
          :pending
          | :running
          | :completed
          | :failed
          | :cancelled
          | :compensated

  @typedoc "Terminal outbox states. Once reached, MUST NOT transition to any other state."
  @type terminal_status :: :completed | :cancelled | :compensated

  @typedoc "The three phases of a directive plan"
  @type phase :: :pre | :effect | :post

  @typedoc "How the runtime handles an input signal when its decision cycle fails"
  @type error_policy :: :reject | :requeue | :escalate

  @typedoc "Whether and when compensation runs on a failed plan"
  @type compensation_policy :: :none | :best_effort

  @typedoc "Controls whether directive outcomes emit signals back to the agent"
  @type outcome_signals_policy :: :none | :failures | :all

  @typedoc "The terminal outcome of a directive execution"
  @type directive_outcome :: :completed | :failed | :cancelled | :compensated

  @typedoc "W3C trace context map, keyed by header name (e.g. 'traceparent')"
  @type trace_context :: %{optional(String.t()) => String.t()}

  @typedoc "Runtime FSM states, matching Section 7.2 of the specification exactly"
  @type runtime_state ::
          :init
          | :idle
          | :deciding
          | :dispatching_pre
          | :checkpointing
          | :submitting_effects
          | :dispatching_post
          | :stopping
          | :stopped
end
