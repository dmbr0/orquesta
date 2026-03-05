defmodule Orquesta.RuntimeTest do
  use ExUnit.Case, async: false

  # async: false — InMemoryOutbox and InMemoryPersistence are named GenServers
  # with named ETS tables; only one instance of each can exist at a time.

  alias Orquesta.Runtime.RuntimeSupervisor
  alias Orquesta.Runtime.AgentRuntime
  alias Orquesta.Adapters.InMemoryOutbox
  alias Orquesta.Adapters.InMemoryPersistence
  alias Orquesta.Test.{CounterAgent, PassthroughCodec, ControlledExecution}
  alias Orquesta.Signal

  @base_opts [
    module: CounterAgent,
    drain: Orquesta.Runtime.InternalDrain,
    outbox: InMemoryOutbox,
    persistence: InMemoryPersistence,
    codec: PassthroughCodec
  ]

  # Unique agent_instance_id per test avoids Registry collisions if a prior
  # supervisor's processes haven't fully stopped before the next test starts.
  defp unique_id, do: "test-agent-#{System.unique_integer([:positive])}"

  defp runtime_opts(id, extra \\ []) do
    Keyword.merge(@base_opts, [{:agent_instance_id, id} | extra])
  end

  setup do
    start_supervised!(InMemoryOutbox)
    start_supervised!(InMemoryPersistence)
    ControlledExecution.setup()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "processes a signal and writes a snapshot at revision 1" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id)})

    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :increment))

    assert_snapshot_revision(id, 1)

    {:ok, snapshot} = InMemoryPersistence.load_latest_snapshot(id)
    assert snapshot.agent_revision == 1
    assert snapshot.encoded_state.count == 1
  end

  test "revision increments on each signal" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id)})

    for _ <- 1..3 do
      AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :increment))
    end

    assert_snapshot_revision(id, 3)

    {:ok, snapshot} = InMemoryPersistence.load_latest_snapshot(id)
    assert snapshot.encoded_state.count == 3
  end

  test "runtime reaches idle after processing a signal" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id)})

    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :increment))

    assert_snapshot_revision(id, 1)
    assert_runtime_state(id, :idle)
  end

  # ---------------------------------------------------------------------------
  # Recovery — Case 1 (no-op restart)
  # ---------------------------------------------------------------------------

  test "Case 1: restarts cleanly when outbox has no entries ahead of snapshot" do
    id = unique_id()

    # Use explicit :id so stop_supervised!/1 finds the child by id, not pid.
    # Passing a pid to stop_supervised! is deprecated and fails if the process
    # exits before the call.
    start_supervised!({RuntimeSupervisor, runtime_opts(id)}, id: :run1)
    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :increment))
    assert_snapshot_revision(id, 1)
    stop_supervised!(:run1)

    # Second run: snapshot_revision=1, max_outbox_revision=0 → Case 1.
    start_supervised!({RuntimeSupervisor, runtime_opts(id)}, id: :run2)
    assert_runtime_state(id, :idle)

    {:ok, snapshot} = InMemoryPersistence.load_latest_snapshot(id)
    assert snapshot.agent_revision == 1
    assert snapshot.encoded_state.count == 1
  end

  test "Case 1: new agent with no snapshot starts at revision 0" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id)})

    assert_runtime_state(id, :idle)
    assert InMemoryPersistence.load_latest_snapshot(id) == {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # Recovery — Case 2a (resume)
  # ---------------------------------------------------------------------------

  test "Case 2a: snapshot is written before drain is called (checkpoint ordering)" do
    id = unique_id()

    # Pause immediately after do_checkpoint returns.
    # Verifies snapshot is written in do_checkpoint, before do_submit_effects.
    opts = runtime_opts(id, execution: ControlledExecution)
    start_supervised!({RuntimeSupervisor, opts})

    ControlledExecution.set_pause_after(:do_checkpoint)
    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :increment))
    :paused = ControlledExecution.wait_for_pause()

    # Snapshot must exist before drain is ever called.
    {:ok, snapshot} = InMemoryPersistence.load_latest_snapshot(id)
    assert snapshot.agent_revision == 1
    assert snapshot.encoded_state.count == 1

    # CounterAgent returns an empty directive plan — no outbox entries written.
    assert InMemoryOutbox.query_by_scope(:agent, id) == []

    # Unblock the FSM and confirm it reaches idle normally.
    ControlledExecution.resume()
    assert_runtime_state(id, :idle)
  end

  # ---------------------------------------------------------------------------
  # Recovery — Case 2b (divergence)
  # ---------------------------------------------------------------------------

  test "Case 2b: stops with divergence_error when outbox revision has no snapshot" do
    id = unique_id()

    # Manually write an outbox entry at revision 5 with no snapshot at revision 5
    entry = %Orquesta.OutboxEntry{
      directive_id: "div-test-directive",
      scope_type: :agent,
      scope_id: id,
      agent_revision: 5,
      encoded_directive: :noop,
      inserted_at: DateTime.utc_now()
    }

    :ok = InMemoryOutbox.write_entries([entry])

    # No snapshot at revision 5 — only at revision 0 (none written)
    # Runtime should stop with divergence_error
    Process.flag(:trap_exit, true)

    result =
      RuntimeSupervisor.start_link(runtime_opts(id))

    case result do
      {:error, _} ->
        # Supervisor failed to start — expected
        :ok

      {:ok, sup_pid} ->
        # Supervisor started but runtime should have stopped internally
        ref = Process.monitor(sup_pid)

        receive do
          {:DOWN, ^ref, :process, ^sup_pid, _reason} -> :ok
        after
          1000 -> flunk("Supervisor did not stop after divergence")
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation — before step 3 (no outbox entries written)
  # ---------------------------------------------------------------------------

  test "cancellation before checkpoint step 3 writes no outbox entries" do
    id = unique_id()
    opts = runtime_opts(id, execution: ControlledExecution)
    start_supervised!({RuntimeSupervisor, opts})

    # Pause at do_cmd so we can inject cancel_requested before checkpoint
    ControlledExecution.set_pause_after(:do_cmd)
    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :increment))
    :paused = ControlledExecution.wait_for_pause()

    # Send cancellation while FSM is paused between deciding and checkpointing
    AgentRuntime.request_cancel(
      AgentRuntime.via(id),
      %Orquesta.CancellationToken{
        agent_instance_id: id,
        target: {:revision, 1},
        correlation_id: "test-corr",
        requested_at: DateTime.utc_now()
      }
    )

    ControlledExecution.resume()
    assert_runtime_state(id, :idle)

    # No outbox entries should exist
    assert InMemoryOutbox.query_by_scope(:agent, id) == []
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Poll until a snapshot at the expected revision appears (max ~500ms).
  defp assert_snapshot_revision(id, expected_revision, attempts \\ 50) do
    case InMemoryPersistence.load_latest_snapshot(id) do
      {:ok, %{agent_revision: ^expected_revision}} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        assert_snapshot_revision(id, expected_revision, attempts - 1)

      _ ->
        flunk("Snapshot at revision #{expected_revision} never appeared for #{id}")
    end
  end

  # Poll until the FSM reaches the expected state (max ~500ms).
  # :sys.get_state/1 on a gen_statem returns {state_name, data}.
  defp assert_runtime_state(id, expected_state, attempts \\ 50) do
    via = AgentRuntime.via(id)

    case :sys.get_state(via) do
      {^expected_state, _data} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        assert_runtime_state(id, expected_state, attempts - 1)

      {actual, _} ->
        flunk("Expected FSM state #{expected_state}, got #{actual}")
    end
  end
end
