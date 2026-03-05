defmodule Orquesta.Adapters.InMemoryOutbox do
  @moduledoc """
  Reference outbox implementation backed by ETS.

  Suitable for testing and single-node development. NOT suitable for
  production use: data is lost on process restart.

  The atomicity guarantee for `write_entries/1` is approximated by
  wrapping all inserts in a single GenServer call. For true atomicity
  across node failures, use a database-backed implementation.
  """

  use GenServer

  @behaviour Orquesta.OutboxBehaviour

  # Suppress extra_range warnings on stub implementations.
  # These functions return :ok in the stub but the behaviour spec
  # correctly includes {:error, reason} for production implementations.
  @dialyzer [
    {:nowarn_function, write_entries: 1},
    {:nowarn_function, transition: 2},
    {:nowarn_function, get_entry: 1},
    {:nowarn_function, query_by_scope: 2},
    {:nowarn_function, query_by_status_scope_revision: 4}
  ]

  alias Orquesta.OutboxEntry
  alias Orquesta.Types

  @table :orquesta_in_memory_outbox

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Orquesta.OutboxBehaviour
  @spec write_entries([OutboxEntry.t()]) :: :ok | {:error, term()}
  def write_entries(entries) do
    GenServer.call(__MODULE__, {:write_entries, entries})
  end

  @impl Orquesta.OutboxBehaviour
  @spec transition(Types.outbox_entry_id(), Types.outbox_status()) ::
          :ok | {:error, :terminal | :not_found | term()}
  def transition(outbox_entry_id, new_status) do
    GenServer.call(__MODULE__, {:transition, outbox_entry_id, new_status})
  end

  @impl Orquesta.OutboxBehaviour
  @spec get_entry(Types.outbox_entry_id()) :: {:ok, OutboxEntry.t()} | {:error, :not_found}
  def get_entry(outbox_entry_id) do
    GenServer.call(__MODULE__, {:get_entry, outbox_entry_id})
  end

  @impl Orquesta.OutboxBehaviour
  @spec query_by_scope(Types.scope_type(), Types.scope_id()) :: [OutboxEntry.t()]
  def query_by_scope(scope_type, scope_id) do
    GenServer.call(__MODULE__, {:query_by_scope, scope_type, scope_id})
  end

  @impl Orquesta.OutboxBehaviour
  @spec query_by_status_scope_revision(
          Types.outbox_status(),
          Types.scope_type(),
          Types.scope_id(),
          Types.agent_revision()
        ) :: [OutboxEntry.t()]
  def query_by_status_scope_revision(status, scope_type, scope_id, agent_revision) do
    GenServer.call(__MODULE__, {:query_by_status_scope_revision, status, scope_type, scope_id, agent_revision})
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:write_entries, entries}, _from, %{table: table} = state) do
    # Atomic insert of all entries
    entries
    |> Enum.map(fn %OutboxEntry{} = entry ->
      {entry.directive_id, entry}
    end)
    |> then(&:ets.insert(table, &1))

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:transition, directive_id, new_status}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, directive_id) do
        [{^directive_id, entry}] ->
          case OutboxEntry.validate_transition(entry, new_status) do
            :ok ->
              updated = %{entry | status: new_status}
              true = :ets.insert(table, {directive_id, updated})
              :ok

            {:error, :terminal} ->
              {:error, :terminal}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:get_entry, directive_id}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, directive_id) do
        [{^directive_id, entry}] -> {:ok, entry}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:query_by_scope, scope_type, scope_id}, _from, %{table: table} = state) do
    # Match all entries and filter by scope
    all = :ets.match(table, {:_, :"$1"})

    entries =
      all
      |> Enum.map(fn [entry] -> entry end)
      |> Enum.filter(fn entry ->
        entry.scope_type == scope_type and entry.scope_id == scope_id
      end)

    {:reply, entries, state}
  end

  @impl GenServer
  def handle_call(
        {:query_by_status_scope_revision, status, scope_type, scope_id, agent_revision},
        _from,
        %{table: table} = state
      ) do
    all = :ets.match(table, {:_, :"$1"})

    entries =
      all
      |> Enum.map(fn [entry] -> entry end)
      |> Enum.filter(fn entry ->
        entry.status == status and
          entry.scope_type == scope_type and
          entry.scope_id == scope_id and
          entry.agent_revision == agent_revision
      end)

    {:reply, entries, state}
  end
end
