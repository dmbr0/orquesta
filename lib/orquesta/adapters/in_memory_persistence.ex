defmodule Orquesta.Adapters.InMemoryPersistence do
  @moduledoc """
  Reference persistence implementation backed by ETS.

  Suitable for testing and single-node development. NOT suitable for
  production use: data is lost on process restart.
  """

  use GenServer

  @behaviour Orquesta.PersistenceBehaviour

  @dialyzer [
    {:nowarn_function, save_snapshot: 1},
    {:nowarn_function, load_latest_snapshot: 1},
    {:nowarn_function, load_snapshot_at_revision: 2},
    {:nowarn_function, upcast: 3}
  ]

  alias Orquesta.AgentSnapshot
  alias Orquesta.Types

  @table :orquesta_in_memory_persistence

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Orquesta.PersistenceBehaviour
  @spec save_snapshot(AgentSnapshot.t()) :: :ok | {:error, term()}
  def save_snapshot(%AgentSnapshot{} = snapshot) do
    GenServer.call(__MODULE__, {:save_snapshot, snapshot})
  end

  @impl Orquesta.PersistenceBehaviour
  @spec load_latest_snapshot(Types.agent_instance_id()) ::
          {:ok, AgentSnapshot.t()} | {:error, :not_found}
  def load_latest_snapshot(agent_instance_id) do
    GenServer.call(__MODULE__, {:load_latest_snapshot, agent_instance_id})
  end

  @impl Orquesta.PersistenceBehaviour
  @spec load_snapshot_at_revision(Types.agent_instance_id(), Types.agent_revision()) ::
          {:ok, AgentSnapshot.t()} | {:error, :not_found}
  def load_snapshot_at_revision(agent_instance_id, revision) do
    GenServer.call(__MODULE__, {:load_snapshot_at_revision, agent_instance_id, revision})
  end

  @impl Orquesta.PersistenceBehaviour
  @spec upcast(term(), Types.schema_version(), Types.schema_version()) ::
          {:ok, term()} | {:error, :no_migration | term()}
  def upcast(encoded, from_version, to_version) when from_version == to_version do
    {:ok, encoded}
  end

  def upcast(_encoded, _from_version, _to_version) do
    # Sequential migration: from_version → from_version+1 → ... → to_version
    {:error, :no_migration}
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:save_snapshot, snapshot}, _from, %{table: table} = state) do
    key = {snapshot.agent_instance_id, snapshot.agent_revision}
    true = :ets.insert(table, {key, snapshot})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:load_latest_snapshot, agent_instance_id}, _from, %{table: table} = state) do
    # Match all entries for this agent_instance_id and find max revision
    matches = :ets.match(table, {{agent_instance_id, :"$1"}, :"$2"})

    result =
      case matches do
        [] ->
          {:error, :not_found}

        entries ->
          # Find entry with maximum revision
          [_max_rev, snapshot] =
            Enum.max_by(entries, fn [revision, _snapshot] -> revision end)

          {:ok, snapshot}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(
        {:load_snapshot_at_revision, agent_instance_id, revision},
        _from,
        %{table: table} = state
      ) do
    key = {agent_instance_id, revision}

    result =
      case :ets.lookup(table, key) do
        [{^key, snapshot}] -> {:ok, snapshot}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end
end
