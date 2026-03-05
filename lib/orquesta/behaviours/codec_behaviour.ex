defmodule Orquesta.CodecBehaviour do
  @moduledoc """
  Serialization seam for agent state, signals, and directives.

  The runtime does not mandate a serialization format. Codecs operate only
  on the CURRENT schema version. Upcasting from older versions to the current
  version occurs before decoding, via `Orquesta.PersistenceBehaviour.upcast/2`.

  Implementations may use JSON, Erlang term storage, MessagePack, or any
  other format appropriate for the persistence backend.
  """

  alias Orquesta.Signal
  alias Orquesta.Directive

  @doc "Encodes agent state struct to a serializable term."
  @callback encode_state(agent :: struct()) :: term()

  @doc "Decodes a serializable term back to the current-version agent struct."
  @callback decode_state(encoded :: term()) :: struct()

  @doc "Encodes a Signal to a serializable term."
  @callback encode_signal(signal :: Signal.t()) :: term()

  @doc "Decodes a serializable term back to a Signal."
  @callback decode_signal(encoded :: term()) :: Signal.t()

  @doc "Encodes a Directive to a serializable term for outbox storage."
  @callback encode_directive(directive :: Directive.t()) :: term()

  @doc "Decodes a serializable term from outbox storage back to a Directive."
  @callback decode_directive(encoded :: term()) :: Directive.t()
end
