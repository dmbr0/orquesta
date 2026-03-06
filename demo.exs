alias Orquesta.Runtime.RuntimeSupervisor
alias Orquesta.Runtime.AgentRuntime
alias Orquesta.Adapters.{InMemoryOutbox, InMemoryPersistence}
alias Orquesta.Signal

# ---------------------------------------------------------------------------
# Inline agent + codec — no dependency on test/support modules
# ---------------------------------------------------------------------------

defmodule Demo.CounterAgent do
  @behaviour Orquesta.AgentBehaviour
  defstruct count: 0
  def initial_state, do: %__MODULE__{}
  def schema_version, do: 1
  def error_policy, do: :reject
  def cmd(%__MODULE__{count: n} = agent, _signal) do
    {:ok, %{agent | count: n + 1}, Orquesta.DirectivePlan.empty()}
  end
end

defmodule Demo.Codec do
  @behaviour Orquesta.CodecBehaviour
  def encode_state(s), do: s
  def decode_state(s), do: s
  def encode_signal(s), do: s
  def decode_signal(s), do: s
  def encode_directive(d), do: d
  def decode_directive(d), do: d
end

# ---------------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------------

IO.puts("\n=== Orquesta Runtime Demo ===\n")

{:ok, _} = InMemoryOutbox.start_link()
{:ok, _} = InMemoryPersistence.start_link()

id = "demo-agent-1"

opts = [
  module: Demo.CounterAgent,
  agent_instance_id: id,
  drain: Orquesta.Runtime.InternalDrain,
  outbox: InMemoryOutbox,
  persistence: InMemoryPersistence,
  codec: Demo.Codec
]

IO.puts("Starting runtime for agent: #{id}")
{:ok, _} = RuntimeSupervisor.start_link(opts)
IO.puts("Runtime started.\n")

IO.puts("--- Sending 3 signals (synchronously) ---")
for i <- 1..3 do
  {:ok, agent} = AgentRuntime.call_signal(AgentRuntime.via(id), Signal.new(id, :increment))
  IO.puts("  Signal #{i} -> agent.count = #{agent.count}")
end

IO.puts("\n--- Checking persisted snapshot ---")
{:ok, snap} = InMemoryPersistence.load_latest_snapshot(id)
IO.puts("  Latest snapshot: revision=#{snap.agent_revision}, count=#{snap.encoded_state.count}")

IO.puts("\n--- Simulating crash + recovery ---")
IO.puts("  Stopping runtime...")
Supervisor.stop(RuntimeSupervisor.via(id))
Process.sleep(100)

IO.puts("  Restarting runtime...")
{:ok, _} = RuntimeSupervisor.start_link(opts)
Process.sleep(100)

{:ok, snap2} = InMemoryPersistence.load_latest_snapshot(id)
IO.puts("  After restart: revision=#{snap2.agent_revision}, count=#{snap2.encoded_state.count}")

IO.puts("\n--- Continuing after recovery ---")
{:ok, agent} = AgentRuntime.call_signal(AgentRuntime.via(id), Signal.new(id, :increment))
IO.puts("  Signal 4 -> agent.count = #{agent.count}")

{:ok, agent} = AgentRuntime.call_signal(AgentRuntime.via(id), Signal.new(id, :increment))
IO.puts("  Signal 5 -> agent.count = #{agent.count}")

IO.puts("\n=== Done! ===\n")
