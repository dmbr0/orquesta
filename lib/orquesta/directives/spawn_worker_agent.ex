defmodule Orquesta.Directives.SpawnWorkerAgent do
  @moduledoc """
  Effect directive: start a `Orquesta.Agents.Worker` instance and give it a task.

  The worker runs its ReAct loop independently under the BEAM supervision tree.
  When the worker finishes, it signals
  `{:worker_result, task, {:ok, output} | {:error, reason}}`
  to the `reply_to` agent instance ID.

  This directive itself returns `:ok` immediately after spawning — it does not
  wait for the worker to finish. The orchestrating agent learns the outcome
  via the `:worker_result` signal.

  ## Args map

    - `:task`           — natural language task description; required
    - `:tools`          — list of tool spec maps (Anthropic format); optional (default: [])
    - `:tool_registry`  — map of tool_name => {module, base_args}; optional (default: %{})
    - `:system_prompt`  — system prompt for the worker LLM; optional
    - `:working_dir`    — sandbox directory path passed to all tool directives; optional
    - `:reply_to`       — agent_instance_id to signal when done; required
    - `:max_turns`      — maximum ReAct loop turns; optional (default: 30)
    - `:drain`          — drain module for the worker runtime; required
    - `:outbox`         — outbox module for the worker runtime; required
    - `:persistence`    — persistence module for the worker runtime; required
    - `:codec`          — codec module for the worker runtime; required
    - `:worker_id`      — optional explicit agent_instance_id; generated if omitted

  ## Idempotency

  If a worker runtime is already registered in `Orquesta.Registry` with the
  derived `worker_id`, this directive is a no-op. The same `worker_id` input
  (derived from the directive_id) always maps to the same worker instance,
  satisfying the outbox idempotency requirement.
  """

  @behaviour Orquesta.DirectiveBehaviour

  require Logger

  alias Orquesta.Agents.Worker
  alias Orquesta.Runtime.RuntimeSupervisor
  alias Orquesta.Runtime.AgentRuntime
  alias Orquesta.Signal

  @type args :: %{
          required(:task) => String.t(),
          required(:reply_to) => String.t(),
          required(:drain) => module(),
          required(:outbox) => module(),
          required(:persistence) => module(),
          required(:codec) => module(),
          optional(:tools) => [map()],
          optional(:tool_registry) => map(),
          optional(:system_prompt) => String.t(),
          optional(:working_dir) => String.t(),
          optional(:max_turns) => pos_integer(),
          optional(:worker_id) => String.t()
        }

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(args, context) when is_map(args) and is_map(context) do
    with :ok <- validate_args(args) do
      worker_id = Map.get(args, :worker_id) || derive_worker_id(context.directive_id)

      case already_running?(worker_id) do
        true ->
          # Idempotent — already started for this directive_id.
          Logger.debug("[SpawnWorkerAgent] worker #{worker_id} already running, skipping spawn")
          :ok

        false ->
          spawn_worker(worker_id, args, context)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec validate_args(map()) :: :ok | {:error, term()}
  defp validate_args(%{task: task, reply_to: reply_to, drain: _, outbox: _, persistence: _, codec: _})
       when is_binary(task) and is_binary(reply_to),
       do: :ok

  defp validate_args(args), do: {:error, {:invalid_args, args}}

  @spec already_running?(String.t()) :: boolean()
  defp already_running?(worker_id) do
    case Registry.lookup(Orquesta.Registry, {AgentRuntime, worker_id}) do
      [] -> false
      [_ | _] -> true
    end
  end

  @spec spawn_worker(String.t(), args(), map()) :: :ok | {:error, term()}
  defp spawn_worker(worker_id, args, context) do
    start_opts = [
      module: Worker,
      agent_instance_id: worker_id,
      drain: args.drain,
      outbox: args.outbox,
      persistence: args.persistence,
      codec: args.codec
    ]

    case RuntimeSupervisor.start_link(start_opts) do
      {:ok, _sup} ->
        send_start_signal(worker_id, args, context)

      {:error, {:already_started, _}} ->
        # Race: another process started it between the Registry check and here.
        Logger.debug("[SpawnWorkerAgent] worker #{worker_id} already started (race), skipping")
        :ok

      {:error, reason} ->
        Logger.error("[SpawnWorkerAgent] failed to start worker #{worker_id}: #{inspect(reason)}")
        {:error, {:spawn_failed, reason}}
    end
  end

  @spec send_start_signal(String.t(), args(), map()) :: :ok
  defp send_start_signal(worker_id, args, context) do
    opts = %{
      task: args.task,
      tools: Map.get(args, :tools, []),
      tool_registry: Map.get(args, :tool_registry, %{}),
      system_prompt: Map.get(args, :system_prompt, default_system_prompt()),
      working_dir: Map.get(args, :working_dir),
      reply_to: args.reply_to,
      max_turns: Map.get(args, :max_turns, 30)
    }

    signal =
      Signal.new(
        worker_id,
        {:start, opts},
        correlation_id: context.correlation_id,
        causation_id: context.directive_id
      )

    via = AgentRuntime.via(worker_id)

    try do
      AgentRuntime.cast_signal(via, signal)
    rescue
      e ->
        Logger.error("[SpawnWorkerAgent] failed to send :start signal to #{worker_id}: #{inspect(e)}")
    end

    :ok
  end

  @spec derive_worker_id(String.t()) :: String.t()
  defp derive_worker_id(directive_id) do
    hash =
      :crypto.hash(:sha256, directive_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "worker-#{hash}"
  end

  @spec default_system_prompt() :: String.t()
  defp default_system_prompt do
    """
    You are a capable AI assistant with access to tools. Complete the given
    task methodically, using the available tools as needed.
    When you have completed the task, respond with your final answer.
    """
  end
end
