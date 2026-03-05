defmodule Orquesta.Runtime.RuntimeSupervisor do
  @moduledoc """
  Top-level supervisor for a single agent runtime instance.

  Supervision tree topology:

      RuntimeSupervisor (one_for_all)
       ├─ AgentRuntime       (gen_statem)
       ├─ DrainSupervisor    (supervisor)
       │   └─ InternalDrain  (GenServer)
       └─ CoordinatorSupervisor (DynamicSupervisor, future)

  `one_for_all` strategy is used because AgentRuntime and DrainSupervisor
  are tightly coupled: if the drain crashes, the runtime must restart to
  re-run startup reconciliation. If the runtime crashes, the drain must
  also restart to prevent stale in-flight state.
  """

  use Supervisor

  alias Orquesta.Runtime.AgentRuntime
  alias Orquesta.Runtime.DrainSupervisor

  @doc "Starts and links a RuntimeSupervisor for one agent instance."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :agent_instance_id)))
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {AgentRuntime, opts},
      {DrainSupervisor, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc "Returns a via tuple for Registry lookup by agent_instance_id."
  @spec via(String.t()) :: {:via, module(), term()}
  def via(agent_instance_id) do
    {:via, Registry, {Orquesta.Registry, {__MODULE__, agent_instance_id}}}
  end
end
