defmodule Orquesta.Runtime.AgentRuntime do
  @moduledoc """
  The agent runtime finite state machine.

  Implemented as an OTP `:gen_statem` using `state_functions` callback mode
  with `state_enter` so each state receives an enter event on transition.

  States (Section 7.2):
    init → idle → deciding → dispatching_pre → checkpointing →
    submitting_effects → dispatching_post → [idle | stopping] → stopped

  All execution steps are dispatched through `data.execution`, which holds a
  module implementing `Orquesta.ExecutionBehaviour`. Dynamic dispatch means
  the Elixir 1.18 compiler types call sites against the callback @spec, not
  the concrete implementation body — preserving all match arms as reachable.
  """

  @behaviour :gen_statem

  require Logger

  alias Orquesta.Runtime.RuntimeData
  alias Orquesta.Signal
  alias Orquesta.CancellationToken
  alias Orquesta.Types

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Starts and links an AgentRuntime under the calling process."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @doc "Sends a signal to the agent for processing. Returns immediately."
  @spec cast_signal(pid(), Signal.t()) :: :ok
  def cast_signal(pid, %Signal{} = signal) do
    :gen_statem.cast(pid, {:signal, signal})
  end

  @doc "Sends a signal and waits for the decision cycle to complete."
  @spec call_signal(pid(), Signal.t(), timeout()) :: {:ok, struct()} | {:error, term()}
  def call_signal(pid, %Signal{} = signal, timeout \\ 5000) do
    :gen_statem.call(pid, {:signal, signal}, timeout)
  end

  @doc "Requests cancellation of a directive or revision."
  @spec request_cancel(pid(), CancellationToken.t()) :: :ok
  def request_cancel(pid, %CancellationToken{} = token) do
    :gen_statem.cast(pid, {:cancel, token})
  end

  @doc "Requests a graceful stop."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    :gen_statem.cast(pid, :stop)
  end

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  @spec init(keyword()) :: {:ok, Types.runtime_state(), RuntimeData.t()}
  def init(opts) do
    data = %RuntimeData{
      module: Keyword.fetch!(opts, :module),
      agent_instance_id: Keyword.fetch!(opts, :agent_instance_id),
      execution: Keyword.get(opts, :execution, Orquesta.Runtime.Execution),
      drain: Keyword.fetch!(opts, :drain),
      outbox: Keyword.fetch!(opts, :outbox),
      persistence: Keyword.fetch!(opts, :persistence),
      codec: Keyword.fetch!(opts, :codec),
      error_policy: Keyword.get(opts, :error_policy, :reject)
    }

    {:ok, :init, data}
  end

  @impl :gen_statem
  def terminate(_reason, _state, _data), do: :ok

  # ---------------------------------------------------------------------------
  # State: init
  # Performs startup recovery (Section 5.4) then transitions to idle.
  # ---------------------------------------------------------------------------

  def init(:enter, _old_state, data) do
    {:keep_state, data, [{:next_event, :internal, :recover}]}
  end

  def init(:internal, :recover, data) do
    case data.execution.do_startup_recovery(data) do
      {:ok, recovered_data}     -> {:next_state, :idle, recovered_data}
      {:resume, recovered_data} -> {:next_state, :submitting_effects, recovered_data}
      {:stop, reason}           -> {:stop, reason, data}
    end
  end

  def init(event_type, event_content, data) do
    handle_common(event_type, event_content, :init, data)
  end

  # ---------------------------------------------------------------------------
  # State: idle
  # Waiting for a signal.
  # ---------------------------------------------------------------------------

  def idle(:enter, _old_state, data) do
    {:keep_state, data.execution.clear_pending(data)}
  end

  def idle(:cast, {:signal, %Signal{} = signal}, data) do
    {:next_state, :deciding, %{data | pending_input: signal}}
  end

  def idle(:cast, {:cancel, _token}, data) do
    # Section 7.5: cancellation in idle has no effect
    {:keep_state, data}
  end

  def idle(:cast, :stop, data) do
    {:next_state, :stopping, data}
  end

  def idle({:call, from}, {:signal, %Signal{} = signal}, data) do
    {:next_state, :deciding, %{data | pending_input: signal}, [{:reply, from, :ok}]}
  end

  def idle(event_type, event_content, data) do
    handle_common(event_type, event_content, :idle, data)
  end

  # ---------------------------------------------------------------------------
  # State: deciding
  # Calls cmd/2 on the agent module and validates directive phases.
  # ---------------------------------------------------------------------------

  def deciding(:enter, _old_state, data) do
    {:keep_state, data, [{:next_event, :internal, :run_cmd}]}
  end

  def deciding(:internal, :run_cmd, %RuntimeData{} = data) do
    # do_cmd returns {:error, reason, new_data} so updated agent state is never
    # discarded — apply_error_policy receives the post-cmd data, not the pre-cmd data.
    case data.execution.do_cmd(data) do
      {:ok, new_data} ->
        {:next_state, :dispatching_pre, new_data}

      {:error, reason, new_data} ->
        Logger.warning("[Orquesta] cmd/2 failed: #{inspect(reason)}")
        {:next_state, :idle, data.execution.apply_error_policy(new_data, reason)}
    end
  end

  def deciding(:cast, {:cancel, _token}, data) do
    {:next_state, :idle, data.execution.apply_error_policy(data, :cancelled)}
  end

  def deciding(event_type, event_content, data) do
    handle_common(event_type, event_content, :deciding, data)
  end

  # ---------------------------------------------------------------------------
  # State: dispatching_pre
  # Executes pre directives synchronously. No I/O permitted.
  # ---------------------------------------------------------------------------

  def dispatching_pre(:enter, _old_state, data) do
    {:keep_state, data, [{:next_event, :internal, :run_pre}]}
  end

  def dispatching_pre(:internal, :run_pre, %RuntimeData{} = data) do
    case data.execution.do_dispatch_pre(data) do
      {:ok, new_data} ->
        {:next_state, :checkpointing, new_data}

      {:error, reason} ->
        Logger.warning("[Orquesta] pre directive failed: #{inspect(reason)}")
        {:next_state, :idle, data.execution.apply_error_policy(data, reason)}
    end
  end

  def dispatching_pre(:cast, {:cancel, _token}, data) do
    {:next_state, :idle, data.execution.apply_error_policy(data, :cancelled)}
  end

  def dispatching_pre(event_type, event_content, data) do
    handle_common(event_type, event_content, :dispatching_pre, data)
  end

  # ---------------------------------------------------------------------------
  # State: checkpointing
  # Executes steps 1-5 from Section 5.3 in order.
  # ---------------------------------------------------------------------------

  def checkpointing(:enter, _old_state, data) do
    {:keep_state, data, [{:next_event, :internal, :run_checkpoint}]}
  end

  def checkpointing(:internal, :run_checkpoint, %RuntimeData{} = data) do
    case data.execution.do_checkpoint(data) do
      {:ok, new_data} ->
        {:next_state, :submitting_effects, new_data}

      {:error, reason} ->
        Logger.error("[Orquesta] checkpoint failed: #{inspect(reason)}")
        {:next_state, :idle, data.execution.apply_error_policy(data, reason)}
    end
  end

  def checkpointing(:cast, {:cancel, _token}, data) do
    # Section 7.5: recorded; do_checkpoint checks it before/after outbox write
    {:keep_state, %{data | cancel_requested: true}}
  end

  def checkpointing(event_type, event_content, data) do
    handle_common(event_type, event_content, :checkpointing, data)
  end

  # ---------------------------------------------------------------------------
  # State: submitting_effects
  # Calls Drain.submit/2 for each outbox entry.
  # ---------------------------------------------------------------------------

  def submitting_effects(:enter, _old_state, data) do
    {:keep_state, data, [{:next_event, :internal, :submit_all}]}
  end

  def submitting_effects(:internal, :submit_all, %RuntimeData{} = data) do
    case data.execution.do_submit_effects(data) do
      {:ok, new_data} ->
        {:next_state, :dispatching_post, new_data}

      {:error, reason} ->
        Logger.error("[Orquesta] effect submission failed: #{inspect(reason)}")
        {:next_state, :idle, data}
    end
  end

  def submitting_effects(:cast, {:cancel, token}, data) do
    # Section 7.5: best-effort cancel via drain
    data.execution.do_best_effort_cancel(data, token)
    {:keep_state, data}
  end

  def submitting_effects(event_type, event_content, data) do
    handle_common(event_type, event_content, :submitting_effects, data)
  end

  # ---------------------------------------------------------------------------
  # State: dispatching_post
  # Post failures MUST NOT prevent transition to idle (Section 7.4).
  # ---------------------------------------------------------------------------

  def dispatching_post(:enter, _old_state, data) do
    {:keep_state, data, [{:next_event, :internal, :run_post}]}
  end

  def dispatching_post(:internal, :run_post, %RuntimeData{} = data) do
    data.execution.do_dispatch_post(data)
    {:next_state, :idle, data}
  end

  def dispatching_post(event_type, event_content, data) do
    handle_common(event_type, event_content, :dispatching_post, data)
  end

  # ---------------------------------------------------------------------------
  # State: stopping / stopped
  # ---------------------------------------------------------------------------

  def stopping(:enter, _old_state, data) do
    {:keep_state, data, [{:next_event, :internal, :do_stop}]}
  end

  def stopping(:internal, :do_stop, data) do
    {:next_state, :stopped, data}
  end

  def stopping(event_type, event_content, data) do
    handle_common(event_type, event_content, :stopping, data)
  end

  def stopped(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def stopped(event_type, event_content, data) do
    handle_common(event_type, event_content, :stopped, data)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec handle_common(:gen_statem.event_type(), term(), Types.runtime_state(), RuntimeData.t()) ::
          :keep_state_and_data
  defp handle_common(event_type, event_content, state, _data) do
    Logger.debug(
      "[Orquesta] unhandled event in #{state}: #{inspect({event_type, event_content})}"
    )

    :keep_state_and_data
  end
end
