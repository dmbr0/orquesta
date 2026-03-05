defmodule Orquesta.DrainBehaviour do
  @moduledoc """
  The seam between the runtime and effect execution.

  Drain implementations are responsible for executing effect directives.
  They MUST read directive content from the outbox using `outbox_entry_id`
  rather than accepting it directly from the runtime caller.

  Two reference implementations are provided:
  - `Orquesta.Adapters.InternalDrain` — Task.Supervisor based, runs in-process
  - External drain — job queue workers (Oban, etc.) reading from a shared outbox

  Drain implementations MUST NOT retry directives with terminal status
  (`:cancelled`, `:compensated`).
  """

  alias Orquesta.Types

  @doc """
  Submits an outbox entry for execution.

  The drain MUST read the directive content from the outbox using the
  provided `outbox_entry_id`. It MUST NOT accept directive content inline.

  The `:running` outbox transition occurs when execution begins, not
  when `submit/2` is called.
  """
  @callback submit(outbox_entry_id :: Types.outbox_entry_id(), opts :: keyword()) ::
              :ok | {:error, reason :: term()}

  @doc """
  Attempts to cancel execution of a submitted directive.

  Cancellation is best-effort once execution has begun. If the directive
  has already reached a terminal state, this MUST return `:ok` (idempotent).
  """
  @callback cancel(outbox_entry_id :: Types.outbox_entry_id(), opts :: keyword()) ::
              :ok | {:error, reason :: term()}

  @doc "Returns the current execution status of a submitted directive."
  @callback status(outbox_entry_id :: Types.outbox_entry_id(), opts :: keyword()) ::
              Types.outbox_status() | {:error, :not_found}
end
