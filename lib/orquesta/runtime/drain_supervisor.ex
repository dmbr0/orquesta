defmodule Orquesta.Runtime.DrainSupervisor do
  @moduledoc """
  Supervises the drain implementation for a single agent runtime instance.

  On startup, the internal drain performs reconciliation:
  queries outbox entries where `status == :running AND scope_id == agent_instance_id
  AND agent_revision == committed_revision`, resets them to `:pending`,
  and resubmits them. This ensures directives interrupted by a drain crash
  are retried safely.

  External drains (Oban, etc.) do not run under this supervisor; they are
  managed by their own infrastructure. The drain module is swappable via
  the `:drain` option passed to the runtime.
  """

  use Supervisor

  alias Orquesta.Runtime.InternalDrain

  @doc "Starts and links a DrainSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, [])
  end

  @impl Supervisor
  def init(opts) do
    drain_module = Keyword.get(opts, :drain, InternalDrain)

    children =
      if drain_module == InternalDrain do
        [{InternalDrain, opts}]
      else
        # External drain: nothing to supervise here
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
