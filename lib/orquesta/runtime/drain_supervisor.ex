defmodule Orquesta.Runtime.DrainSupervisor do
  @moduledoc """
  Supervises the drain implementation for a single agent runtime instance.

  The internal drain does NOT reconcile on its own startup. Reconciliation
  is triggered by `AgentRuntime` via `DrainBehaviour.reconcile/2` after
  startup recovery completes and the correct `committed_revision` is known.
  This two-phase approach prevents the drain from querying the outbox at
  revision 0 when the agent may actually be recovering to a later revision.

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
