defmodule Orquesta.Test.NoopDirective do
  @moduledoc false

  @behaviour Orquesta.DirectiveBehaviour

  @impl Orquesta.DirectiveBehaviour
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  def execute(_args, _data), do: :ok
end
