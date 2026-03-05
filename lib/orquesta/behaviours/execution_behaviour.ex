defmodule Orquesta.ExecutionBehaviour do
  @moduledoc """
  Behaviour for the agent execution layer.

  `AgentRuntime` calls all execution steps through this behaviour rather than
  directly, for two reasons:

  1. **Type safety**: dynamic dispatch (`data.execution.do_startup_recovery(data)`)
     is typed against the callback spec, not the implementation body. This lets
     stub implementations return placeholder values without confusing the Elixir
     1.18 compiler's interprocedural type inference at the call site.

  2. **Testability**: tests can inject a mock or controlled implementation by
     passing `execution: MyMockExecution` in the `AgentRuntime` opts, without
     starting real persistence/outbox adapters.

  ## do_cmd error return

  `do_cmd/1` returns a three-element error tuple `{:error, reason, RuntimeData.t()}`
  rather than a two-element tuple. This preserves the updated agent state that
  `cmd/2` may have produced even on the error path. The FSM passes the updated
  data to `apply_error_policy/2` so the agent's state is never silently discarded.
  """

  alias Orquesta.Runtime.RuntimeData
  alias Orquesta.CancellationToken

  @doc "Section 5.4 — startup recovery."
  @callback do_startup_recovery(RuntimeData.t()) ::
              {:ok, RuntimeData.t()}
              | {:resume, RuntimeData.t()}
              | {:stop, term()}

  @doc """
  Section 7.4 deciding — call module.cmd/2 and validate phases.

  Returns `{:error, reason, RuntimeData.t()}` on failure so that any agent
  state produced by `cmd/2` is preserved and passed to `apply_error_policy/2`.
  """
  @callback do_cmd(RuntimeData.t()) ::
              {:ok, RuntimeData.t()} | {:error, term(), RuntimeData.t()}

  @doc "Section 7.4 dispatching_pre — execute pre directives synchronously."
  @callback do_dispatch_pre(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}

  @doc "Section 5.3 — five-step checkpoint protocol."
  @callback do_checkpoint(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}

  @doc "Section 7.4 submitting_effects — submit each outbox entry to the drain."
  @callback do_submit_effects(RuntimeData.t()) :: {:ok, RuntimeData.t()} | {:error, term()}

  @doc "Section 7.4 dispatching_post — execute post directives, log failures, never raise."
  @callback do_dispatch_post(RuntimeData.t()) :: :ok

  @doc "Section 7.5 — best-effort cancel via drain."
  @callback do_best_effort_cancel(RuntimeData.t(), CancellationToken.t()) :: :ok

  @doc "Section 4.1 — apply error_policy to a failed signal."
  @callback apply_error_policy(RuntimeData.t(), term()) :: RuntimeData.t()

  @doc "Reset all transient fields after a decision cycle."
  @callback clear_pending(RuntimeData.t()) :: RuntimeData.t()
end
