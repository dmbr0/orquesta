defmodule Orquesta.Test.RecordingDrain do
  @moduledoc false
  @moduledoc """
  Test drain that records submit/cancel calls in ETS.

  Useful for asserting that the runtime submitted the correct outbox entries
  without needing real directive modules. Calls are stored as:

      {:submitted, outbox_entry_id}
      {:cancelled, outbox_entry_id}

  Retrieve with `RecordingDrain.calls/0`.
  """

  @behaviour Orquesta.DrainBehaviour

  @table :orquesta_recording_drain

  @spec setup() :: :ok
  def setup do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :duplicate_bag])
    end
    reset()
    :ok
  end

  @spec calls() :: [{:submitted | :cancelled, String.t()}]
  def calls do
    :ets.tab2list(@table)
  end

  @spec reset() :: true
  def reset do
    :ets.delete_all_objects(@table)
  end

  @impl Orquesta.DrainBehaviour
  def submit(outbox_entry_id, _opts) do
    :ets.insert(@table, {:submitted, outbox_entry_id})
    :ok
  end

  @impl Orquesta.DrainBehaviour
  def cancel(outbox_entry_id, _opts) do
    :ets.insert(@table, {:cancelled, outbox_entry_id})
    :ok
  end

  @impl Orquesta.DrainBehaviour
  def status(_outbox_entry_id, _opts), do: :pending

  @impl Orquesta.DrainBehaviour
  def reconcile(_agent_instance_id, _committed_revision), do: :ok
end
