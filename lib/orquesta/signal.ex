defmodule Orquesta.Signal do
  @moduledoc """
  An immutable input to the agent runtime.

  Signals originate from users, other agents, or runtime events (such as
  directive outcome signals). Every signal carries causal metadata enabling
  full request-chain tracing.

  Signal structs MUST NOT be mutated after construction.
  """

  alias Orquesta.Types

  @type t :: %__MODULE__{
          signal_id: Types.signal_id(),
          agent_instance_id: Types.agent_instance_id(),
          correlation_id: Types.correlation_id(),
          causation_id: Types.causation_id() | nil,
          payload: term(),
          metadata: map()
        }

  @enforce_keys [:signal_id, :agent_instance_id, :correlation_id]
  defstruct [
    :signal_id,
    :agent_instance_id,
    :correlation_id,
    :causation_id,
    :payload,
    metadata: %{}
  ]

  @doc "Constructs a new signal with a generated signal_id."
  @spec new(Types.agent_instance_id(), term(), keyword()) :: t()
  def new(agent_instance_id, payload, opts \\ []) do
    %__MODULE__{
      signal_id: generate_id(),
      agent_instance_id: agent_instance_id,
      correlation_id: Keyword.get(opts, :correlation_id, generate_id()),
      causation_id: Keyword.get(opts, :causation_id),
      payload: payload,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
