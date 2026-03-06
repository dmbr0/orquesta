defmodule Orquesta.Agents.Worker do
  @moduledoc """
  A generalised ReAct loop agent.

  Receives a task, a tool set, and a system prompt. Runs an LLM-driven
  loop calling tools until the LLM produces an `end_turn` stop reason,
  then signals the final result upstream.

  ## State machine

      :idle
        → signal: {:start, task, tools, system_prompt, context}
        → emit CallLLM
        → :waiting_for_llm

      :waiting_for_llm
        → signal: {:llm_result, directive_id, result}
        → if tool_use: emit tool directive
        → :waiting_for_tool

        → if end_turn: signal {:worker_result, id, {:ok, text}} upstream
        → :done

      :waiting_for_tool
        → signal: {:tool_result, directive_id, result}
        → append tool result to conversation, emit CallLLM
        → :waiting_for_llm

  ## Tool spec format

  Each tool in the `tools` list is a map matching Anthropic's tool schema:

      %{
        name: "bash",
        description: "Run a shell command",
        schema: %{
          type: "object",
          properties: %{command: %{type: "string", description: "..."}},
          required: ["command"]
        }
      }

  ## Upstream result signal

  When the worker finishes (end_turn) it sends
  `{:worker_result, worker_instance_id, {:ok, final_text} | {:error, reason}}`
  to the `reply_to` pid or agent_instance_id supplied in `:start`.

  The caller is responsible for routing this signal to the correct upstream
  agent (e.g. the orchestrating Thinker or Planner).
  """

  @behaviour Orquesta.AgentBehaviour

  require Logger

  alias Orquesta.Directive
  alias Orquesta.DirectivePlan
  alias Orquesta.Directives.CallLLM
  alias Orquesta.Providers.Anthropic
  alias Orquesta.Providers.Anthropic.Response.LLMResult
  alias Orquesta.Runtime.AgentRuntime
  alias Orquesta.Signal

  # ---------------------------------------------------------------------------
  # State struct
  # ---------------------------------------------------------------------------

  @type tool_directive_module :: module()
  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          schema: map()
        }
  @type tool_registry :: %{String.t() => {tool_directive_module(), map()}}
  @type status :: :idle | :waiting_for_llm | :waiting_for_tool | :done | :failed

  @type t :: %__MODULE__{
          status: status(),
          task: String.t() | nil,
          system_prompt: String.t() | nil,
          tools: [tool_spec()],
          tool_registry: tool_registry(),
          working_dir: String.t() | nil,
          reply_to: String.t() | nil,
          messages: [map()],
          pending_directive_id: String.t() | nil,
          pending_tool_call_id: String.t() | nil,
          turn_count: non_neg_integer(),
          max_turns: pos_integer()
        }

  defstruct [
    :task,
    :system_prompt,
    :working_dir,
    :reply_to,
    :pending_directive_id,
    :pending_tool_call_id,
    status: :idle,
    tools: [],
    tool_registry: %{},
    messages: [],
    turn_count: 0,
    max_turns: 30
  ]

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
  def cmd(%__MODULE__{status: :idle} = agent, %{payload: {:start, opts}} = signal) do
    handle_start(agent, opts, signal.correlation_id)
  end

  def cmd(%__MODULE__{status: :waiting_for_llm} = agent,
          %{payload: {:llm_result, directive_id, %LLMResult{} = result}}) do
    handle_llm_result(agent, directive_id, result)
  end

  def cmd(%__MODULE__{status: :waiting_for_tool} = agent,
          %{payload: {:tool_result, directive_id, result}}) do
    handle_tool_result(agent, directive_id, result)
  end

  def cmd(%__MODULE__{} = agent, signal) do
    Logger.warning("[Worker] unexpected signal #{inspect(signal.payload)} in #{agent.status}")
    {:error, {:unexpected_signal, signal.payload}, agent, DirectivePlan.empty()}
  end

  # ---------------------------------------------------------------------------
  # Private — cmd handlers
  # ---------------------------------------------------------------------------

  @spec handle_start(t(), map(), String.t()) :: {:ok, t(), DirectivePlan.t()}
  defp handle_start(agent, opts, correlation_id) do
    task = Map.fetch!(opts, :task)
    tools = Map.get(opts, :tools, [])
    system_prompt = Map.get(opts, :system_prompt, "You are a helpful assistant.")
    working_dir = Map.get(opts, :working_dir)
    reply_to = Map.get(opts, :reply_to)
    max_turns = Map.get(opts, :max_turns, 30)
    tool_registry = Map.get(opts, :tool_registry, %{})

    messages = [%{role: :user, content: task}]
    directive_id = make_directive_id("llm", 0, task)

    directive = build_call_llm(directive_id, messages, system_prompt, tools, correlation_id)
    plan = %DirectivePlan{effect: [directive]}

    new_agent = %{
      agent
      | status: :waiting_for_llm,
        task: task,
        system_prompt: system_prompt,
        tools: tools,
        tool_registry: tool_registry,
        working_dir: working_dir,
        reply_to: reply_to,
        messages: messages,
        pending_directive_id: directive_id,
        turn_count: 0,
        max_turns: max_turns
    }

    {:ok, new_agent, plan}
  end

  # finish/2 always returns {:ok, _, _} so the error branch is excluded from
  # the spec.
  @spec handle_llm_result(t(), String.t(), LLMResult.t()) :: {:ok, t(), DirectivePlan.t()}
  defp handle_llm_result(agent, directive_id, result) do
    # Guard: ignore stale results.
    if directive_id != agent.pending_directive_id do
      Logger.warning("[Worker] ignoring stale llm_result for directive #{directive_id}")
      {:ok, agent, DirectivePlan.empty()}
    else
      updated_messages = Anthropic.append_assistant(agent.messages, result)
      new_agent = %{agent | messages: updated_messages}

      cond do
        agent.turn_count >= agent.max_turns ->
          finish(new_agent, {:error, :max_turns_exceeded})

        LLMResult.wants_tools?(result) ->
          handle_tool_use(new_agent, result)

        true ->
          # end_turn — we're done
          final_text = LLMResult.text(result)
          finish(%{new_agent | status: :done}, {:ok, final_text})
      end
    end
  end

  @spec handle_tool_result(t(), String.t(), {:ok, term()} | {:error, term()}) ::
          {:ok, t(), DirectivePlan.t()}
  defp handle_tool_result(agent, directive_id, result) do
    if directive_id != agent.pending_directive_id do
      Logger.warning("[Worker] ignoring stale tool_result for directive #{directive_id}")
      {:ok, agent, DirectivePlan.empty()}
    else
      tool_call_id = agent.pending_tool_call_id

      content =
        case result do
          {:ok, output} -> to_string(output)
          {:error, reason} -> "Error: #{inspect(reason)}"
        end

      updated_messages =
        Anthropic.append_tool_result(agent.messages, tool_call_id, content)

      correlation_id = make_correlation_id(agent)
      llm_directive_id = make_directive_id("llm", agent.turn_count + 1, agent.task)

      directive =
        build_call_llm(
          llm_directive_id,
          updated_messages,
          agent.system_prompt,
          agent.tools,
          correlation_id
        )

      plan = %DirectivePlan{effect: [directive]}

      new_agent = %{
        agent
        | status: :waiting_for_llm,
          messages: updated_messages,
          pending_directive_id: llm_directive_id,
          pending_tool_call_id: nil,
          turn_count: agent.turn_count + 1
      }

      {:ok, new_agent, plan}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — tool dispatch
  # ---------------------------------------------------------------------------

  @spec handle_tool_use(t(), LLMResult.t()) :: {:ok, t(), DirectivePlan.t()}
  defp handle_tool_use(agent, result) do
    case LLMResult.tool_calls(result) do
      [] ->
        finish(%{agent | status: :done}, {:ok, LLMResult.text(result)})

      [tool_call | _rest] ->
        # Execute one tool call at a time (sequential). Parallel execution
        # can be added later by fanning out and gathering results.
        dispatch_tool(agent, tool_call)
    end
  end

  @spec dispatch_tool(t(), Orquesta.Providers.Anthropic.Response.ToolUseBlock.t()) ::
          {:ok, t(), DirectivePlan.t()}
  defp dispatch_tool(agent, tool_call) do
    tool_directive_id = make_directive_id("tool", agent.turn_count, tool_call.name)

    case Map.get(agent.tool_registry, tool_call.name) do
      nil -> dispatch_unknown_tool(agent, tool_call)
      {tool_module, base_args} ->
        dispatch_known_tool(agent, tool_call, tool_module, base_args, tool_directive_id)
    end
  end

  @spec dispatch_unknown_tool(t(), Orquesta.Providers.Anthropic.Response.ToolUseBlock.t()) ::
          {:ok, t(), DirectivePlan.t()}
  defp dispatch_unknown_tool(agent, tool_call) do
    # Unknown tool — return error as tool result so LLM can recover.
    Logger.warning("[Worker] unknown tool: #{tool_call.name}")

    error_messages =
      Anthropic.append_tool_result(
        agent.messages,
        tool_call.id,
        "Error: unknown tool #{tool_call.name}"
      )

    correlation_id = make_correlation_id(agent)
    llm_directive_id = make_directive_id("llm", agent.turn_count + 1, agent.task)

    directive =
      build_call_llm(
        llm_directive_id,
        error_messages,
        agent.system_prompt,
        agent.tools,
        correlation_id
      )

    new_agent = %{
      agent
      | status: :waiting_for_llm,
        messages: error_messages,
        pending_directive_id: llm_directive_id,
        turn_count: agent.turn_count + 1
    }

    {:ok, new_agent, %DirectivePlan{effect: [directive]}}
  end

  @spec dispatch_known_tool(
          t(),
          Orquesta.Providers.Anthropic.Response.ToolUseBlock.t(),
          module(),
          map(),
          String.t()
        ) :: {:ok, t(), DirectivePlan.t()}
  defp dispatch_known_tool(agent, tool_call, tool_module, base_args, tool_directive_id) do
    args =
      base_args
      |> Map.merge(tool_call.input)
      |> maybe_put_working_dir(agent.working_dir)

    directive = %Directive{
      directive_id: tool_directive_id,
      module: tool_module,
      args: args,
      correlation_id: make_correlation_id(agent)
    }

    new_agent = %{
      agent
      | status: :waiting_for_tool,
        pending_directive_id: tool_directive_id,
        pending_tool_call_id: tool_call.id
    }

    {:ok, new_agent, %DirectivePlan{effect: [directive]}}
  end

  # ---------------------------------------------------------------------------
  # Private — completion
  # ---------------------------------------------------------------------------

  @spec finish(t(), {:ok, String.t()} | {:error, term()}) :: {:ok, t(), DirectivePlan.t()}
  defp finish(agent, result) do
    new_agent = %{agent | status: if(match?({:ok, _}, result), do: :done, else: :failed)}

    # If reply_to is set, signal result upstream.
    case agent.reply_to do
      nil -> :ok
      reply_target -> signal_upstream(reply_target, agent, result)
    end

    {:ok, new_agent, DirectivePlan.empty()}
  end

  @spec signal_upstream(String.t(), t(), {:ok, String.t()} | {:error, term()}) :: :ok
  defp signal_upstream(reply_to, agent, result) do
    signal =
      Signal.new(
        reply_to,
        {:worker_result, agent.task, result},
        correlation_id: make_correlation_id(agent)
      )

    via = AgentRuntime.via(reply_to)

    try do
      AgentRuntime.cast_signal(via, signal)
    rescue
      e ->
        Logger.error("[Worker] failed to signal upstream #{reply_to}: #{inspect(e)}")
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private — helpers
  # ---------------------------------------------------------------------------

  @spec build_call_llm(String.t(), [map()], String.t(), [map()], String.t()) :: Directive.t()
  defp build_call_llm(directive_id, messages, system_prompt, tools, correlation_id) do
    args =
      %{
        model: :claude_sonnet,
        messages: messages,
        system: system_prompt,
        max_tokens: 8192,
        fallback_models: [:claude_haiku]
      }
      |> maybe_put_tools(tools)

    %Directive{
      directive_id: directive_id,
      module: CallLLM,
      args: args,
      correlation_id: correlation_id
    }
  end

  @spec maybe_put_tools(map(), [map()]) :: map()
  defp maybe_put_tools(args, []), do: args
  defp maybe_put_tools(args, tools), do: Map.put(args, :tools, tools)

  @spec maybe_put_working_dir(map(), String.t() | nil) :: map()
  defp maybe_put_working_dir(args, nil), do: args
  defp maybe_put_working_dir(args, working_dir), do: Map.put(args, :working_dir, working_dir)

  @spec make_directive_id(String.t(), non_neg_integer(), String.t()) :: String.t()
  defp make_directive_id(type, turn, context) do
    hash =
      :crypto.hash(:sha256, context)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "worker-#{type}-t#{turn}-#{hash}"
  end

  @spec make_correlation_id(t()) :: String.t()
  defp make_correlation_id(agent) do
    hash =
      :crypto.hash(:sha256, agent.task || "")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "worker-#{hash}-t#{agent.turn_count}"
  end
end
