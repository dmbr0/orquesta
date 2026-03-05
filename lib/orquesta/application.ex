defmodule Orquesta.Application do
  @moduledoc """
  OTP Application entry point for Orquesta.

  Starts the shared infrastructure required by all runtime instances:

  - `Orquesta.Registry` — process registry used by `RuntimeSupervisor`
    and `InternalDrain` to locate processes by `agent_instance_id`.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Orquesta.Registry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Orquesta.Supervisor)
  end
end
