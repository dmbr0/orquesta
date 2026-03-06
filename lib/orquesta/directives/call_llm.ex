defmodule Orquesta.Directives.CallLLM do
  @moduledoc """
Effect directive for calling an LLM provider.

Implements `Orquesta.DirectiveBehaviour`. The runtime persists this
directive to the outbox before execution, guaranteeing exactly-once
delivery even across crashes.

## How results reach the agent

`execute/2` returns only `:ok | {:error, reason}` — the directive
protocol has no return channel for values. After a successful LLM
call, this directive sends the result back as a signal:

    {:llm_result, directive_id, %LLMResult{}}

The agent handles that signal in a subsequent `cmd/2` call. The
`directive_id` lets the agent correlate which call a result belongs
to when multiple concurrent calls are outstanding.

## Args map

Build a `%Orquesta.Directive{}` with `module: CallLLM` and an `args`
map containing:

  - `:model`           — atom (`:claude_opus`, `:claude_sonnet`,
                         `:claude_haiku`) or a raw model string; required
  - `:messages`        — non-empty list of `%{role:, content:}` maps; required
  - `:system`          — system prompt string; optional
  - `:tools`           — list of tool spec maps; optional
  - `:stream_to`       — pid; text tokens forwarded as `{:llm_chunk, text}`; optional
  - `:max_tokens`      — integer; optional (provider default: 8192)
  - `:temperature`     — float 0.0–1.0; optional
  - `:timeout_ms`      — integer; optional (default: 120_000)
  - `:fallback_models` — list of model atoms to try if the primary fails; optional

## Example agent

    defmodule MyApp.Agents.Summariser do
      @behaviour Orquesta.AgentBehaviour

      alias Orquesta.Directive
      alias Orquesta.DirectivePlan
      alias Orquesta.Directives.CallLLM
      alias Orquesta.Providers.Anthropic.Response.LLMResult

      defstruct [:summary]

      def initial_state, do: %__MODULE__{}
      def schema_version, do: 1
      def error_policy, do: :reject

      # Step 1 — signal arrives, emit the directive
      def cmd(%__MODULE__{} = agent, %{payload: {:summarise, text}, correlation_id: cid}) do
        directive = %Directive{
          directive_id: "summarise-" <> hash(text),
          module: CallLLM,
          correlation_id: cid,
          args: %{
            model: :claude_sonnet,
            system: "Summarise the following in one sentence.",
            messages: [%{role: :user, content: text}],
            max_tokens: 256,
            fallback_models: [:claude_haiku]
          }
        }

        {:ok, agent, %DirectivePlan{effect: [directive]}}
      end

      # Step 2 — CallLLM signals the result back; agent handles it
      def cmd(%__MODULE__{} = agent, %{payload: {:llm_result, _id, %LLMResult{} = result}}) do
        summary = LLMResult.text(result)
        {:ok, %{agent | summary: summary}, DirectivePlan.empty()}
      end

      defp hash(text) do
        :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)
      end
    end
"""

  @behaviour Orquesta.DirectiveBehaviour

  @dialyzer {:no_underspecs, put_opt: 3}

  require Logger

  alias Orquesta.Providers.Anthropic
  alias Orquesta.Providers.Anthropic.Response.LLMResult
  alias Orquesta.Runtime.AgentRuntime
  alias Orquesta.Signal

  @type args :: %{
          required(:model) => atom() | String.t(),
          required(:messages) => [map()],
          optional(:system) => String.t(),
          optional(:tools) => [map()],
          optional(:stream_to) => pid(),
          optional(:max_tokens) => pos_integer(),
          optional(:temperature) => float(),
          optional(:timeout_ms) => pos_integer(),
          optional(:fallback_models) => [atom() | String.t()]
        }

  # ---------------------------------------------------------------------------
  # DirectiveBehaviour callbacks
  # ---------------------------------------------------------------------------

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(args, context)
      when is_map(args) and is_map(context) do
    with :ok <- validate_args(args) do
      opts = extract_opts(args)
      fallbacks = Map.get(args, :fallback_models, [])

      case call_with_fallback(args.model, args.messages, opts, fallbacks) do
        {:ok, result} ->
          signal_result_to_agent(context.agent_instance_id, context.directive_id,
                                 context.correlation_id, context.causation_id, result)

        {:error, reason} ->
          Logger.error(
            "[CallLLM] all providers failed for directive #{context.directive_id}: " <>
              inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec validate_args(args()) :: :ok | {:error, term()}
  defp validate_args(%{model: _, messages: messages}) when is_list(messages) and messages != [] do
    :ok
  end

  defp validate_args(%{messages: []}), do: {:error, :empty_messages}
  defp validate_args(%{messages: nil}), do: {:error, :nil_messages}
  defp validate_args(%{model: nil}), do: {:error, :nil_model}
  defp validate_args(_args), do: {:error, :missing_required_args}

  @spec extract_opts(args()) :: keyword()
  defp extract_opts(args) do
    []
    |> put_opt(:system, Map.get(args, :system))
    |> put_opt(:tools, Map.get(args, :tools))
    |> put_opt(:stream_to, Map.get(args, :stream_to))
    |> put_opt(:max_tokens, Map.get(args, :max_tokens))
    |> put_opt(:temperature, Map.get(args, :temperature))
    |> put_opt(:timeout_ms, Map.get(args, :timeout_ms))
  end

  @spec put_opt(keyword(), atom(), term()) :: keyword()
  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec call_with_fallback(atom() | String.t(), [map()], keyword(), [atom() | String.t()]) ::
          {:ok, LLMResult.t()} | {:error, term()}
  defp call_with_fallback(model, messages, opts, []) do
    Anthropic.call(model, messages, opts)
  end

  defp call_with_fallback(model, messages, opts, [next | rest]) do
    case Anthropic.call(model, messages, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Logger.warning(
          "[CallLLM] #{inspect(model)} failed (#{inspect(reason)}), " <>
            "trying fallback #{inspect(next)}"
        )

        call_with_fallback(next, messages, opts, rest)
    end
  end

  @spec signal_result_to_agent(
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          LLMResult.t()
        ) :: :ok | {:error, term()}
  defp signal_result_to_agent(agent_instance_id, directive_id, correlation_id, causation_id, result) do
    signal = Signal.new(
      agent_instance_id,
      {:llm_result, directive_id, result},
      correlation_id: correlation_id,
      causation_id: causation_id
    )

    via = AgentRuntime.via(agent_instance_id)

    try do
      AgentRuntime.cast_signal(via, signal)
      :ok
    rescue
      e ->
        Logger.error(
          "[CallLLM] failed to signal result back to agent #{agent_instance_id}: " <>
            inspect(e)
        )

        {:error, {:signal_failed, e}}
    end
  end
end
