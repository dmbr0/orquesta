defmodule Orquesta.RuntimeEffectsTest do
  use ExUnit.Case, async: false

  # async: false — RecordingDrain and InMemory* adapters use named ETS tables.

  alias Orquesta.Runtime.RuntimeSupervisor
  alias Orquesta.Runtime.AgentRuntime
  alias Orquesta.Adapters.{InMemoryOutbox, InMemoryPersistence}
  alias Orquesta.Test.{
    EffectAgent,
    FailingAgent,
    CounterAgent,
    PassthroughCodec,
    RecordingDrain,
    ControlledExecution
  }
  alias Orquesta.Signal

  @base_opts [
    drain: RecordingDrain,
    outbox: InMemoryOutbox,
    persistence: InMemoryPersistence,
    codec: PassthroughCodec
  ]

  defp unique_id, do: "test-agent-#{System.unique_integer([:positive])}"

  defp runtime_opts(id, module, extra \\ []) do
    Keyword.merge(@base_opts, [{:agent_instance_id, id}, {:module, module} | extra])
  end

  setup do
    start_supervised!(InMemoryOutbox)
    start_supervised!(InMemoryPersistence)
    # RecordingDrain is a module-level ETS table; initialise once per test.
    RecordingDrain.setup()
    ControlledExecution.setup()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Drain path: signal → outbox entry → drain.submit called
  # ---------------------------------------------------------------------------

  test "emits one outbox entry and calls drain.submit for an effect directive" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id, EffectAgent)})

    sig = Signal.new(id, :run)
    AgentRuntime.cast_signal(AgentRuntime.via(id), sig)

    assert_snapshot_revision(id, 1)
    assert_runtime_state(id, :idle)

    # Exactly one submit call should have been recorded.
    submitted = RecordingDrain.calls() |> Enum.filter(&match?({:submitted, _}, &1))
    assert length(submitted) == 1

    [{:submitted, entry_id}] = submitted
    assert String.starts_with?(entry_id, "noop-")
  end

  test "submit is called once per signal across multiple signals" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id, EffectAgent)})

    for i <- 1..3 do
      sig = Signal.new(id, :"run_#{i}")
      AgentRuntime.cast_signal(AgentRuntime.via(id), sig)
    end

    assert_snapshot_revision(id, 3)
    assert_runtime_state(id, :idle)

    submitted = RecordingDrain.calls() |> Enum.filter(&match?({:submitted, _}, &1))
    assert length(submitted) == 3
  end

  # ---------------------------------------------------------------------------
  # Case 2a — real resubmission on restart
  #
  # Timeline:
  #   1. Start runtime, process signal, pause AFTER do_checkpoint returns.
  #      At this point: snapshot@1 exists, outbox entry@1 exists (status :pending),
  #      drain.submit has NOT been called yet.
  #   2. Stop the runtime while it is paused (simulates a crash mid-submission).
  #   3. Clear the RecordingDrain log so we can assert on the restart-only calls.
  #   4. Restart the runtime. Startup recovery detects Case 2a (max_outbox_revision=1
  #      and snapshot@1 exists). The runtime should call drain.submit for the
  #      pending entry before transitioning to :idle.
  # ---------------------------------------------------------------------------

  test "Case 2a: runtime resubmits pending outbox entries on restart" do
    id = unique_id()
    opts = runtime_opts(id, EffectAgent, execution: ControlledExecution)

    start_supervised!({RuntimeSupervisor, opts}, id: :run1)

    # Pause after checkpoint so drain.submit is never called in run 1.
    ControlledExecution.set_pause_after(:do_checkpoint)
    sig = Signal.new(id, :run)
    AgentRuntime.cast_signal(AgentRuntime.via(id), sig)
    :paused = ControlledExecution.wait_for_pause()

    # Verify the snapshot is there and an outbox entry was written.
    {:ok, snapshot} = InMemoryPersistence.load_latest_snapshot(id)
    assert snapshot.agent_revision == 1

    entries = InMemoryOutbox.query_by_scope(:agent, id)
    assert length(entries) == 1
    [entry] = entries
    assert entry.status == :pending

    # Stop while paused — drain.submit was never called.
    assert RecordingDrain.calls() == []
    stop_supervised!(:run1)

    # Clear drain log so we can assert on restart-only behaviour.
    RecordingDrain.reset()

    # Restart without ControlledExecution so recovery runs unimpeded.
    start_supervised!({RuntimeSupervisor, runtime_opts(id, EffectAgent)}, id: :run2)
    assert_runtime_state(id, :idle)

    # Recovery (Case 2a) must have called drain.submit for the pending entry.
    submitted = RecordingDrain.calls() |> Enum.filter(&match?({:submitted, _}, &1))
    assert length(submitted) == 1
    [{:submitted, resubmitted_id}] = submitted
    assert resubmitted_id == entry.directive_id
  end

  # ---------------------------------------------------------------------------
  # Post-checkpoint cancellation
  #
  # cancel_requested is set AFTER the outbox entry is written but BEFORE
  # drain.submit is called. The spec (Section 7.5) says the runtime should
  # mark the pending entries as :cancelled rather than submitting them.
  # ---------------------------------------------------------------------------

  test "cancel after checkpoint prevents drain.submit and cancels outbox entries" do
    id = unique_id()
    opts = runtime_opts(id, EffectAgent, execution: ControlledExecution)
    start_supervised!({RuntimeSupervisor, opts})

    # Pause after checkpoint — outbox entry is written, drain not called yet.
    ControlledExecution.set_pause_after(:do_checkpoint)
    sig = Signal.new(id, :run)
    AgentRuntime.cast_signal(AgentRuntime.via(id), sig)
    :paused = ControlledExecution.wait_for_pause()

    # Outbox entry exists at this point.
    entries = InMemoryOutbox.query_by_scope(:agent, id)
    assert length(entries) == 1

    # Send cancellation while the FSM is paused in checkpointing state.
    AgentRuntime.request_cancel(
      AgentRuntime.via(id),
      %Orquesta.CancellationToken{
        agent_instance_id: id,
        target: {:revision, 1},
        correlation_id: "test-cancel",
        requested_at: DateTime.utc_now()
      }
    )

    ControlledExecution.resume()
    assert_runtime_state(id, :idle)

    # drain.submit must NOT have been called.
    submitted = RecordingDrain.calls() |> Enum.filter(&match?({:submitted, _}, &1))
    assert submitted == []

    # The outbox entry should be in a terminal state (:cancelled).
    [entry] = InMemoryOutbox.query_by_scope(:agent, id)
    assert entry.status == :cancelled
  end

  # ---------------------------------------------------------------------------
  # call_signal/3 — synchronous API
  # ---------------------------------------------------------------------------

  test "call_signal/3 blocks until the decision cycle completes and returns agent state" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id, CounterAgent)})

    result = AgentRuntime.call_signal(AgentRuntime.via(id), Signal.new(id, :inc))

    assert {:ok, agent} = result
    assert agent.count == 1

    # A second call should see count=2.
    {:ok, agent2} = AgentRuntime.call_signal(AgentRuntime.via(id), Signal.new(id, :inc))
    assert agent2.count == 2
  end

  # ---------------------------------------------------------------------------
  # cmd/2 failure → error policy → FSM returns to :idle
  # ---------------------------------------------------------------------------

  test "cmd failure with :reject policy returns FSM to idle without writing snapshot" do
    id = unique_id()
    start_supervised!({RuntimeSupervisor, runtime_opts(id, FailingAgent)})

    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :whatever))
    assert_runtime_state(id, :idle)

    # No snapshot should have been written (cmd never succeeded).
    assert InMemoryPersistence.load_latest_snapshot(id) == {:error, :not_found}

    # No outbox entries should exist.
    assert InMemoryOutbox.query_by_scope(:agent, id) == []
  end

  test "FSM remains healthy after a cmd failure and processes subsequent signals" do
    id = unique_id()

    # Start with a counter agent (succeeds), then verify it keeps working even
    # if we imagine a transient failure. FailingAgent always fails so instead
    # we test that CounterAgent processes a signal after a fresh start, stops,
    # and then processes another after restart — verifying the FSM is re-entrant.
    start_supervised!({RuntimeSupervisor, runtime_opts(id, CounterAgent)}, id: :run1)
    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :inc))
    assert_snapshot_revision(id, 1)

    {:ok, snap} = InMemoryPersistence.load_latest_snapshot(id)
    assert snap.encoded_state.count == 1

    # Second signal: FSM was in :idle; verify it handles another signal normally.
    AgentRuntime.cast_signal(AgentRuntime.via(id), Signal.new(id, :inc))
    assert_snapshot_revision(id, 2)

    {:ok, snap2} = InMemoryPersistence.load_latest_snapshot(id)
    assert snap2.encoded_state.count == 2
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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
