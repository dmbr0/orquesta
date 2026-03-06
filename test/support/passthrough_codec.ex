defmodule Orquesta.Test.PassthroughCodec do
  @moduledoc false

  @behaviour Orquesta.CodecBehaviour

  @impl Orquesta.CodecBehaviour
  def encode_state(agent), do: agent

  @impl Orquesta.CodecBehaviour
  def decode_state(encoded), do: encoded

  @impl Orquesta.CodecBehaviour
  def encode_signal(signal), do: signal

  @impl Orquesta.CodecBehaviour
  def decode_signal(encoded), do: encoded

  @impl Orquesta.CodecBehaviour
  def encode_directive(directive), do: directive

  @impl Orquesta.CodecBehaviour
  def decode_directive(encoded), do: encoded
end
