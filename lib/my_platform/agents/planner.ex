defmodule MyPlatform.Agents.Planner do
  @moduledoc """
  Example planner agent demonstrating `CallLLM` directive usage.

  Receives a `:plan_project` signal carrying a spec string.
  Calls Claude once (thinker pattern — no streaming, no tools).
  Parses the JSON response into tasks.
  Emits one `TaskSignal` per task for downstream worker agents.

  ## State machine

      :idle
        → :planning    (on :plan_project signal — emits CallLLM directive)
        → :distributing (on :llm_result signal — emits TaskSignals)
        → :awaiting    (waiting for workers to complete)
        → :done        (on final task_complete signal)
  """

  @behaviour Orquesta.AgentBehaviour

  require Logger

  alias Orquesta.Directive
  alias Orquesta.DirectivePlan
  alias Orquesta.Directives.CallLLM
  alias Orquesta.Providers.Anthropic.Response.LLMResult

  # ---------------------------------------------------------------------------
  # State struct
  # ---------------------------------------------------------------------------

  @type status :: :idle | :planning | :distributing | :awaiting | :done

  @type t :: %__MODULE__{
          status: status(),
          spec: String.t() | nil,
          pending_directive_id: String.t() | nil,
          tasks: [map()],
          remaining_task_ids: [String.t()]
        }

  defstruct [
    :spec,
    :pending_directive_id,
    status: :idle,
    tasks: [],
    remaining_task_ids: []
  ]

  @system_prompt """
  You are a software project planner. Break a project specification into
  concrete, parallelisable implementation tasks.

  Respond with JSON ONLY — no prose, no markdown fences:
  {
    "tasks": [
      {
        "id": "task_1",
        "title": "short imperative title",
        "description": "what to implement",
        "depends_on": []
      }
    ]
  }

  Rules:
  - Each task must be completable by one engineer in under 2 hours.
  - Tasks that can run in parallel must not depend on each other.
  - "depends_on" lists task ids within the same response.
  - Maximum 8 tasks.
  """

  # ---------------------------------------------------------------------------
  # AgentBehaviour callbacks
  # ---------------------------------------------------------------------------

  @impl Orquesta.AgentBehaviour
  @spec initial_state() :: t()
  def initial_state, do: %__MODULE__{}

  @impl Orquesta.AgentBehaviour
  @spec schema_version() :: non_neg_integer()
  def schema_version, do: 1

  @impl Orquesta.AgentBehaviour
  @spec error_policy() :: Orquesta.Types.error_policy()
  def error_policy, do: :reject

  @impl Orquesta.AgentBehaviour
  @spec cmd(t(), Orquesta.Signal.t()) ::
          {:ok, t(), DirectivePlan.t()}
          | {:error, term(), t(), DirectivePlan.t()}
  def cmd(%__MODULE__{status: :idle} = agent, %{payload: {:plan_project, spec}})
      when is_binary(spec) do
    handle_plan_project(agent, spec)
  end

  def cmd(%__MODULE__{status: :planning} = agent,
          %{payload: {:llm_result, directive_id, %LLMResult{} = result}}) do
    handle_llm_result(agent, directive_id, result)
  end

  def cmd(%__MODULE__{status: :awaiting} = agent,
          %{payload: {:task_complete, task_id}}) do
    handle_task_complete(agent, task_id)
  end

  def cmd(%__MODULE__{} = agent, signal) do
    Logger.warning(
      "[Planner] unexpected signal #{inspect(signal.payload)} in status #{agent.status}"
    )

    {:error, {:unexpected_signal, signal.payload}, agent, DirectivePlan.empty()}
  end

  # ---------------------------------------------------------------------------
  # Private — cmd handlers
  # ---------------------------------------------------------------------------

  @spec handle_plan_project(t(), String.t()) :: {:ok, t(), DirectivePlan.t()}
  defp handle_plan_project(agent, spec) do
    # Stable directive_id derived from spec content so identical requests
    # are idempotent — the outbox will not re-execute the same directive_id.
    directive_id = "plan-" <> content_hash(spec)

    directive = %Directive{
      directive_id: directive_id,
      module: CallLLM,
      correlation_id: "planner-#{directive_id}",
      args: %{
        model: :claude_opus,
        system: @system_prompt,
        messages: [%{role: :user, content: "Project spec:\n\n#{spec}"}],
        max_tokens: 4000,
        fallback_models: [:claude_sonnet]
      }
    }

    plan = %DirectivePlan{effect: [directive]}
    new_agent = %{agent | status: :planning, spec: spec, pending_directive_id: directive_id}
    {:ok, new_agent, plan}
  end

  @spec handle_llm_result(t(), String.t(), LLMResult.t()) ::
          {:ok, t(), DirectivePlan.t()} | {:error, term(), t(), DirectivePlan.t()}
  defp handle_llm_result(agent, directive_id, result) do
    # Guard: ignore stale results from a prior planning attempt.
    if directive_id != agent.pending_directive_id do
      Logger.warning("[Planner] ignoring stale llm_result for directive #{directive_id}")
      {:ok, agent, DirectivePlan.empty()}
    else
      text = LLMResult.text(result)

      case parse_tasks(text) do
        {:ok, tasks} ->
          task_ids = Enum.map(tasks, & &1["id"])

          new_agent = %{agent |
            status: :awaiting,
            tasks: tasks,
            remaining_task_ids: task_ids,
            pending_directive_id: nil
          }

          {:ok, new_agent, DirectivePlan.empty()}

        {:error, reason} ->
          Logger.warning("[Planner] JSON parse failed: #{inspect(reason)}, retrying")
          retry_planning(agent, text, reason)
      end
    end
  end

  @spec handle_task_complete(t(), String.t()) :: {:ok, t(), DirectivePlan.t()}
  defp handle_task_complete(agent, task_id) do
    remaining = Enum.reject(agent.remaining_task_ids, &(&1 == task_id))
    new_agent = %{agent | remaining_task_ids: remaining}

    if remaining == [] do
      {:ok, %{new_agent | status: :done}, DirectivePlan.empty()}
    else
      {:ok, new_agent, DirectivePlan.empty()}
    end
  end

  @spec retry_planning(t(), String.t(), term()) ::
          {:ok, t(), DirectivePlan.t()} | {:error, term(), t(), DirectivePlan.t()}
  defp retry_planning(agent, bad_response, reason) do
    directive_id = "plan-retry-" <> content_hash(bad_response)

    corrected_messages = [
      %{role: :user, content: "Project spec:\n\n#{agent.spec}"},
      %{role: :assistant, content: bad_response},
      %{
        role: :user,
        content:
          "Your previous response could not be parsed as JSON: #{inspect(reason)}. " <>
            "Please respond with valid JSON only, exactly matching the schema."
      }
    ]

    directive = %Directive{
      directive_id: directive_id,
      module: CallLLM,
      correlation_id: "planner-retry-#{directive_id}",
      args: %{
        model: :claude_opus,
        system: @system_prompt,
        messages: corrected_messages,
        max_tokens: 4000
      }
    }

    plan = %DirectivePlan{effect: [directive]}
    new_agent = %{agent | status: :planning, pending_directive_id: directive_id}
    {:ok, new_agent, plan}
  end

  # ---------------------------------------------------------------------------
  # Private — helpers
  # ---------------------------------------------------------------------------

  @spec parse_tasks(String.t()) :: {:ok, [map()]} | {:error, term()}
  defp parse_tasks(text) when is_binary(text) do
    clean =
      text
      |> String.replace(~r/```json\s*/i, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    case Jason.decode(clean) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) and tasks != [] ->
        {:ok, tasks}

      {:ok, %{"tasks" => []}} ->
        {:error, :empty_task_list}

      {:ok, other} ->
        {:error, {:unexpected_shape, other}}

      {:error, reason} ->
        {:error, {:json_decode_failed, inspect(reason)}}
    end
  end

  @spec content_hash(String.t()) :: String.t()
  defp content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
