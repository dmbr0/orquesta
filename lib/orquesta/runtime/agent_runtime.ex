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

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :agent_instance_id)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc "Starts and links an AgentRuntime under the calling process."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    agent_instance_id = Keyword.fetch!(opts, :agent_instance_id)
    name = {:via, Registry, {Orquesta.Registry, {__MODULE__, agent_instance_id}}}
    :gen_statem.start_link(name, __MODULE__, opts, [])
  end

  @doc "Returns the via tuple used to locate this runtime in `Orquesta.Registry`."
  @spec via(Types.agent_instance_id()) :: {:via, module(), term()}
  def via(agent_instance_id) do
    {:via, Registry, {Orquesta.Registry, {__MODULE__, agent_instance_id}}}
  end

  @doc "Sends a signal to the agent for processing. Returns immediately."
  @spec cast_signal(pid() | :gen_statem.server_ref(), Signal.t()) :: :ok
  def cast_signal(pid, %Signal{} = signal) do
    :gen_statem.cast(pid, {:signal, signal})
  end

  @doc "Sends a signal and waits for the decision cycle to complete."
  @spec call_signal(pid() | :gen_statem.server_ref(), Signal.t(), timeout()) :: {:ok, struct()} | {:error, term()}
  def call_signal(pid, %Signal{} = signal, timeout \\ 5000) do
    :gen_statem.call(pid, {:signal, signal}, timeout)
  end

  @doc "Requests cancellation of a directive or revision."
  @spec request_cancel(pid() | :gen_statem.server_ref(), CancellationToken.t()) :: :ok
  def request_cancel(pid, %CancellationToken{} = token) do
    :gen_statem.cast(pid, {:cancel, token})
  end

  @doc "Requests a graceful stop."
  @spec stop(pid() | :gen_statem.server_ref()) :: :ok
  def stop(pid) do
    :gen_statem.cast(pid, :stop)
  end

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: [:state_functions]

  @impl :gen_statem
  @spec init(keyword()) :: {:ok, Types.runtime_state(), RuntimeData.t(), [:gen_statem.action_type()]}
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

    # Queue the recover event immediately — :next_event in init/1 is always
    # valid because it runs before the FSM loop starts, not in a state enter.
    {:ok, :init, data, [{:next_event, :internal, :recover}]}
  end

  @impl :gen_statem
  def terminate(_reason, _state, _data), do: :ok

  # ---------------------------------------------------------------------------
  # State: init
  # Performs startup recovery (Section 5.4) then transitions to idle.
  # The :recover internal event is queued by init/1, not by a state enter
  # callback — :next_event is not a permitted action in state enter callbacks.
  # ---------------------------------------------------------------------------

  def init(:internal, :recover, data) do
    case data.execution.do_startup_recovery(data) do
      {:ok, recovered_data} ->
        {:next_state, :idle, recovered_data}

      {:resume, recovered_data} ->
        :gen_statem.cast(self(), :run_submit_effects)
        {:next_state, :submitting_effects, recovered_data}

      {:stop, reason} ->
        {:stop, reason, data}
    end
  end

  def init(event_type, event_content, data) do
    handle_common(event_type, event_content, :init, data)
  end

  # ---------------------------------------------------------------------------
  # State: idle
  # Waiting for a signal.
  # ---------------------------------------------------------------------------

  def idle(:cast, {:signal, %Signal{} = signal}, data) do
    # Attach :run_cmd so deciding starts work as soon as the state is entered.
    {:next_state, :deciding, %{data | pending_input: signal},
     [{:next_event, :internal, :run_cmd}]}
  end

  def idle(:cast, {:cancel, _token}, data) do
    # Section 7.5: cancellation in idle has no effect.
    {:keep_state, data}
  end

  def idle(:cast, :stop, data) do
    {:next_state, :stopping, data, [{:next_event, :internal, :do_stop}]}
  end

  def idle({:call, from}, {:signal, %Signal{} = signal}, data) do
    # Store the caller; reply will be sent in dispatching_post with {:ok, agent}.
    {:next_state, :deciding, %{data | pending_input: signal, pending_caller: from},
     [{:next_event, :internal, :run_cmd}]}
  end

  def idle(event_type, event_content, data) do
    handle_common(event_type, event_content, :idle, data)
  end

  # ---------------------------------------------------------------------------
  # State: deciding
  # Calls cmd/2 on the agent module and validates directive phases.
  # ---------------------------------------------------------------------------

  def deciding(:internal, :run_cmd, %RuntimeData{} = data) do
    # do_cmd returns {:error, reason, new_data} so updated agent state is never
    # discarded — apply_error_policy receives the post-cmd data, not the pre-cmd data.
    case data.execution.do_cmd(data) do
      {:ok, new_data} ->
        {:next_state, :dispatching_pre, new_data, [{:next_event, :internal, :run_pre}]}

      {:error, reason, new_data} ->
        Logger.warning("[Orquesta] cmd/2 failed: #{inspect(reason)}")
        cleared = data.execution.apply_error_policy(new_data, reason)

        actions =
          case data.pending_caller do
            nil  -> []
            from -> [{:reply, from, {:error, reason}}]
          end

        {:next_state, :idle, %{cleared | pending_caller: nil}, actions}
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

  def dispatching_pre(:internal, :run_pre, %RuntimeData{} = data) do
    case data.execution.do_dispatch_pre(data) do
      {:ok, new_data} ->
        {:next_state, :checkpointing, new_data, [{:next_event, :internal, :run_checkpoint}]}

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

  def checkpointing(:internal, :run_checkpoint, %RuntimeData{} = data) do
    case data.execution.do_checkpoint(data) do
      {:ok, new_data} ->
        # Cast to self so the message lands in the process mailbox rather than
        # gen_statem's internal event list. A cancel cast sent before resume()
        # is already in the mailbox; FIFO ordering ensures cancel fires first.
        :gen_statem.cast(self(), :run_submit_effects)
        {:next_state, :submitting_effects, new_data}

      {:error, reason} ->
        Logger.error("[Orquesta] checkpoint failed: #{inspect(reason)}")
        {:next_state, :idle, data.execution.apply_error_policy(data, reason)}
    end
  end

  def checkpointing(:cast, {:cancel, _token}, data) do
    # Section 7.5: recorded; do_checkpoint checks it before/after outbox write.
    {:keep_state, %{data | cancel_requested: true}}
  end

  def checkpointing(event_type, event_content, data) do
    handle_common(event_type, event_content, :checkpointing, data)
  end

  # ---------------------------------------------------------------------------
  # State: submitting_effects
  # Calls Drain.submit/2 for each outbox entry.
  # The :submit_all internal event is attached by whichever transition enters
  # this state (checkpointing success or init recovery resume).
  # ---------------------------------------------------------------------------

  # :cast :run_submit_effects — triggered by cast-to-self in checkpointing success
  # and init recovery. Because this is a mailbox message (not an internal event),
  # any cancel cast that arrived before it is processed first (FIFO order).
  def submitting_effects(:cast, :run_submit_effects, %RuntimeData{} = data) do
    run_submit_effects(data)
  end

  # :internal :submit_all — kept for forward compatibility if needed.
  def submitting_effects(:internal, :submit_all, %RuntimeData{} = data) do
    run_submit_effects(data)
  end

  def submitting_effects(:cast, {:cancel, _token}, data) do
    # Section 7.5 — cancel arrived before drain.submit. Because :run_submit_effects
    # is a cast (mailbox), a cancel cast sent before it lands first (FIFO). Cancel
    # the outbox entries directly and transition to idle without calling drain.
    Enum.each(data.outbox_entry_ids, fn entry_id ->
      _ = data.outbox.transition(entry_id, :cancelled)
    end)

    {:next_state, :idle, data.execution.clear_pending(data)}
  end

  def submitting_effects(event_type, event_content, data) do
    handle_common(event_type, event_content, :submitting_effects, data)
  end

  # ---------------------------------------------------------------------------
  # State: dispatching_post
  # Post failures MUST NOT prevent transition to idle (Section 7.4).
  # clear_pending is called here so it runs exactly once per decision cycle,
  # on the transition out of dispatching_post rather than on entry to idle.
  # ---------------------------------------------------------------------------

  def dispatching_post(:internal, :run_post, %RuntimeData{} = data) do
    data.execution.do_dispatch_post(data)
    cleared = data.execution.clear_pending(data)

    # If this cycle was initiated by a call_signal/3, reply now with the
    # updated agent struct. clear_pending/1 nilifies pending_caller, so capture
    # it from `data` before clearing.
    actions =
      case data.pending_caller do
        nil  -> []
        from -> [{:reply, from, {:ok, data.agent}}]
      end

    {:next_state, :idle, %{cleared | pending_caller: nil}, actions}
  end

  def dispatching_post(event_type, event_content, data) do
    handle_common(event_type, event_content, :dispatching_post, data)
  end

  # ---------------------------------------------------------------------------
  # State: stopping / stopped
  # The :do_stop internal event is attached by idle when it receives :stop.
  # ---------------------------------------------------------------------------

  def stopping(:internal, :do_stop, data) do
    {:next_state, :stopped, data}
  end

  def stopping(event_type, event_content, data) do
    handle_common(event_type, event_content, :stopping, data)
  end

  def stopped(event_type, event_content, data) do
    handle_common(event_type, event_content, :stopped, data)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec run_submit_effects(RuntimeData.t()) :: :gen_statem.state_function_result()
  defp run_submit_effects(%RuntimeData{} = data) do
    case data.execution.do_submit_effects(data) do
      {:ok, new_data} ->
        {:next_state, :dispatching_post, new_data, [{:next_event, :internal, :run_post}]}

      {:error, reason} ->
        Logger.error("[Orquesta] effect submission failed: #{inspect(reason)}")
        {:next_state, :idle, data}
    end
  end

  @spec handle_common(:gen_statem.event_type(), term(), Types.runtime_state(), RuntimeData.t()) ::
          :keep_state_and_data | {:keep_state_and_data, [:postpone]}
  # Signal casts that arrive while the FSM is busy (deciding, checkpointing, etc.)
  # are postponed rather than dropped. Gen_statem replays postponed events on the
  # next state transition — they will be processed when the FSM returns to :idle.
  defp handle_common(:cast, {:signal, _signal}, state, _data)
       when state not in [:idle, :stopping, :stopped] do
    {:keep_state_and_data, [:postpone]}
  end

  defp handle_common(event_type, event_content, state, _data) do
    Logger.debug(
      "[Orquesta] unhandled event in #{state}: #{inspect({event_type, event_content})}"
    )

    :keep_state_and_data
  end
end
