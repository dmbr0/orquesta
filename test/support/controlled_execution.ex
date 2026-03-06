defmodule Orquesta.Test.ControlledExecution do
  @moduledoc false
  @moduledoc """
  ExecutionBehaviour wrapper that delegates to `Orquesta.Runtime.Execution`
  but supports test-controlled pausing and failure injection.

  A test process calls `set_pause_after/1` to register a breakpoint, then
  sends a signal to the runtime. When the runtime reaches that step, it
  sends `{:paused, step}` to the test process and blocks until `resume/0`
  is called.

  Failure injection: call `set_fail_at/2` to make a specific step return
  `{:error, reason}` instead of delegating to the real implementation.
  """

  @behaviour Orquesta.ExecutionBehaviour

  alias Orquesta.Runtime.Execution
  alias Orquesta.Runtime.RuntimeData
  alias Orquesta.CancellationToken

  # ETS table holds control signals keyed by test pid
  @table :orquesta_controlled_execution

  @spec setup() :: :ok
  def setup do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @spec set_pause_after(atom()) :: :ok
  def set_pause_after(step) do
    :ets.insert(@table, {{:pause_after, self()}, step})
    :ok
  end

  @spec set_fail_at(atom(), term()) :: :ok
  def set_fail_at(step, reason) do
    :ets.insert(@table, {{:fail_at, self()}, {step, reason}})
    :ok
  end

  @spec wait_for_pause(timeout()) :: :paused
  def wait_for_pause(timeout \\ 1000) do
    receive do
      {:paused, _step} -> :paused
    after
      timeout -> raise "timeout waiting for execution pause"
    end
  end

  @spec resume() :: :ok
  def resume do
    receive do
      {:waiting, pid} ->
        send(pid, :resume)
        :ok
    after
      500 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # ExecutionBehaviour callbacks — all delegate through maybe_pause/2
  # ---------------------------------------------------------------------------

  @impl Orquesta.ExecutionBehaviour
  def do_startup_recovery(%RuntimeData{} = data) do
    delegate(:do_startup_recovery, fn -> Execution.do_startup_recovery(data) end)
  end

  @impl Orquesta.ExecutionBehaviour
  def do_cmd(%RuntimeData{} = data) do
    delegate(:do_cmd, fn -> Execution.do_cmd(data) end)
  end

  @impl Orquesta.ExecutionBehaviour
  def do_dispatch_pre(%RuntimeData{} = data) do
    delegate(:do_dispatch_pre, fn -> Execution.do_dispatch_pre(data) end)
  end

  @impl Orquesta.ExecutionBehaviour
  def do_checkpoint(%RuntimeData{} = data) do
    delegate(:do_checkpoint, fn -> Execution.do_checkpoint(data) end)
  end

  @impl Orquesta.ExecutionBehaviour
  def do_submit_effects(%RuntimeData{} = data) do
    delegate(:do_submit_effects, fn -> Execution.do_submit_effects(data) end)
  end

  @impl Orquesta.ExecutionBehaviour
  def do_dispatch_post(%RuntimeData{} = data) do
    Execution.do_dispatch_post(data)
  end

  @impl Orquesta.ExecutionBehaviour
  def do_best_effort_cancel(%RuntimeData{} = data, %CancellationToken{} = token) do
    Execution.do_best_effort_cancel(data, token)
  end

  @impl Orquesta.ExecutionBehaviour
  def apply_error_policy(%RuntimeData{} = data, reason) do
    Execution.apply_error_policy(data, reason)
  end

  @impl Orquesta.ExecutionBehaviour
  def clear_pending(%RuntimeData{} = data) do
    Execution.clear_pending(data)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec delegate(atom(), (-> term())) :: term()
  defp delegate(step, real_fn) do
    test_pid = controlling_test_pid()

    cond do
      fail_at?(test_pid, step) ->
        {_step, reason} = :ets.lookup_element(@table, {:fail_at, test_pid}, 2)
        :ets.delete(@table, {:fail_at, test_pid})
        {:error, reason}

      pause_after?(test_pid, step) ->
        result = real_fn.()
        :ets.delete(@table, {:pause_after, test_pid})
        send(test_pid, {:paused, step})
        # Send {:waiting, self()} so resume/0 knows which pid to unblock.
        send(test_pid, {:waiting, self()})

        receive do
          :resume -> result
        end

      true ->
        real_fn.()
    end
  end

  @spec controlling_test_pid() :: pid() | nil
  defp controlling_test_pid do
    # Walk the ancestor chain to find a pid that has registered a control entry
    [self() | Process.get(:"$ancestors", [])]
    |> Enum.find(fn pid ->
      is_pid(pid) and (
        :ets.member(@table, {:pause_after, pid}) or
        :ets.member(@table, {:fail_at, pid})
      )
    end)
  end

  @spec pause_after?(pid() | nil, atom()) :: boolean()
  defp pause_after?(nil, _step), do: false

  defp pause_after?(test_pid, step) do
    case :ets.lookup(@table, {:pause_after, test_pid}) do
      [{_, ^step}] -> true
      _ -> false
    end
  end

  @spec fail_at?(pid() | nil, atom()) :: boolean()
  defp fail_at?(nil, _step), do: false

  defp fail_at?(test_pid, step) do
    case :ets.lookup(@table, {:fail_at, test_pid}) do
      [{_, {^step, _reason}}] -> true
      _ -> false
    end
  end
end
