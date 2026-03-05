defmodule Orquesta.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude API provider.

  Handles blocking and streaming calls to the Anthropic Messages API.
  Both code paths produce the same `%LLMResult{}` so callers never need
  to know how the call was made.

  ## Configuration

      config :orquesta, Orquesta.Providers.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        base_url: "https://api.anthropic.com",  # optional — for proxies
        api_version: "2023-06-01"               # optional

  ## Model atoms

      :claude_opus   -> "claude-opus-4-5-20251101"
      :claude_sonnet -> "claude-sonnet-4-5-20251016"
      :claude_haiku  -> "claude-haiku-4-5-20251001"

  ## Usage

      # Blocking call
      {:ok, result} = Anthropic.call(:claude_sonnet, messages, system: "You are...")

      # Streaming — text chunks sent to stream_to pid as {:llm_chunk, text}
      {:ok, result} = Anthropic.call(:claude_sonnet, messages, stream_to: self())

      # With tools
      {:ok, result} = Anthropic.call(:claude_sonnet, messages, tools: [my_tool_spec])

  ## Message format

  Messages are maps with `:role` (`:user` | `:assistant`) and `:content`
  (a string or a list of content blocks for tool results).
  """

  require Logger

  alias Orquesta.Providers.Anthropic.{Response, SSE}
  alias Response.LLMResult

  @api_version "2023-06-01"

  @model_strings %{
    claude_opus: "claude-opus-4-5-20251101",
    claude_sonnet: "claude-sonnet-4-5-20251016",
    claude_haiku: "claude-haiku-4-5-20251001"
  }

  @type message :: %{role: :user | :assistant, content: String.t() | [map()]}
  @type tool_spec :: %{name: String.t(), description: String.t(), schema: map()}
  @type call_opt ::
          {:system, String.t()}
          | {:tools, [tool_spec()]}
          | {:stream_to, pid()}
          | {:max_tokens, pos_integer()}
          | {:temperature, float()}
          | {:timeout_ms, pos_integer()}

  @doc """
  Calls the Anthropic Messages API.

  ## Options

    - `:system`      — system prompt string
    - `:tools`       — list of tool specs
    - `:stream_to`   — pid; text chunks sent as `{:llm_chunk, text}`
    - `:max_tokens`  — integer, default 8192
    - `:temperature` — float 0.0–1.0
    - `:timeout_ms`  — request timeout in milliseconds, default 120_000
  """
  @spec call(atom() | String.t(), [message()], [call_opt()]) ::
          {:ok, LLMResult.t()} | {:error, term()}
  def call(model_atom, messages, opts \\ [])
      when is_list(messages) and messages != [] and is_list(opts) do
    model = resolve_model(model_atom)
    stream_to = Keyword.get(opts, :stream_to)
    body = build_body(model, messages, opts)
    headers = build_headers(stream_to != nil)
    req = build_req(opts)

    if is_pid(stream_to) do
      call_streaming(req, body, headers, stream_to)
    else
      call_blocking(req, body, headers)
    end
  end

  @doc """
  Appends an assistant message to a message list.

  Converts `%LLMResult{}` content blocks back to Anthropic's wire format
  so the conversation can continue.
  """
  @spec append_assistant([message()], LLMResult.t()) :: [message()]
  def append_assistant(messages, %LLMResult{content: content}) when is_list(messages) do
    wire_content =
      Enum.map(content, fn
        %Response.TextBlock{text: text} ->
          %{"type" => "text", "text" => text}

        %Response.ToolUseBlock{id: id, name: name, input: input} ->
          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      end)

    messages ++ [%{role: "assistant", content: wire_content}]
  end

  @doc """
  Appends a tool result to a message list.

  Use when handling `:tool_use` stop reason — build the result for each
  tool call, then call again with the updated message list.
  """
  @spec append_tool_result([message()], String.t(), String.t()) :: [message()]
  def append_tool_result(messages, tool_use_id, content)
      when is_list(messages) and is_binary(tool_use_id) and is_binary(content) do
    tool_result_msg = %{
      role: "user",
      content: [%{
        "type" => "tool_result",
        "tool_use_id" => tool_use_id,
        "content" => content
      }]
    }

    messages ++ [tool_result_msg]
  end

  # ---------------------------------------------------------------------------
  # Private — request construction
  # ---------------------------------------------------------------------------

  @spec resolve_model(atom() | String.t()) :: String.t()
  defp resolve_model(atom) when is_atom(atom) do
    case Map.get(@model_strings, atom) do
      nil ->
        raise ArgumentError,
              "Unknown model atom: #{inspect(atom)}. " <>
                "Known atoms: #{inspect(Map.keys(@model_strings))}"

      string ->
        string
    end
  end

  defp resolve_model(string) when is_binary(string), do: string

  @spec build_body(String.t(), [message()], [call_opt()]) :: map()
  defp build_body(model, messages, opts) do
    base = %{
      model: model,
      max_tokens: Keyword.get(opts, :max_tokens, 8192),
      messages: normalise_messages(messages)
    }

    base
    |> put_if_present(:system, Keyword.get(opts, :system))
    |> put_if_present(:tools, build_tools(Keyword.get(opts, :tools)))
    |> put_if_present(:temperature, Keyword.get(opts, :temperature))
  end

  @spec normalise_messages([message()]) :: [map()]
  defp normalise_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} when is_binary(content) ->
        %{"role" => to_string(role), "content" => content}

      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => content}

      msg when is_map(msg) ->
        msg
    end)
  end

  @spec build_tools([tool_spec()] | nil) :: [map()] | nil
  defp build_tools(nil), do: nil
  defp build_tools([]), do: nil

  defp build_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      %{name: name, description: desc, schema: schema} ->
        %{"name" => name, "description" => desc, "input_schema" => schema}

      tool when is_map(tool) ->
        tool
    end)
  end

  @spec build_headers(boolean()) :: [{String.t(), String.t()}]
  defp build_headers(streaming) do
    api_key =
      config(:api_key) ||
        System.get_env("ANTHROPIC_API_KEY") ||
        raise RuntimeError,
              "ANTHROPIC_API_KEY not configured. " <>
                "Set env var or `config :orquesta, Orquesta.Providers.Anthropic, api_key: ...`"

    base = [
      {"x-api-key", api_key},
      {"anthropic-version", config(:api_version) || @api_version},
      {"content-type", "application/json"}
    ]

    if streaming do
      [{"accept", "text/event-stream"} | base]
    else
      base
    end
  end

  @spec build_req([call_opt()]) :: Req.Request.t()
  defp build_req(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)
    base_url = config(:base_url) || "https://api.anthropic.com"

    Req.new(
      base_url: base_url,
      receive_timeout: timeout_ms,
      # Retries are handled at the directive level, not here.
      retry: false
    )
  end

  # ---------------------------------------------------------------------------
  # Private — blocking call
  # ---------------------------------------------------------------------------

  @spec call_blocking(Req.Request.t(), map(), [{String.t(), String.t()}]) ::
          {:ok, LLMResult.t()} | {:error, term()}
  defp call_blocking(req, body, headers) do
    case Req.post(req, url: "/v1/messages", json: body, headers: headers) do
      {:ok, %{status: 200, body: response_body}} ->
        Response.parse(response_body)

      {:ok, %{status: status, body: response_body}} ->
        {:error, parse_api_error(status, response_body)}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — streaming call
  # ---------------------------------------------------------------------------

  @spec call_streaming(Req.Request.t(), map(), [{String.t(), String.t()}], pid()) ::
          {:ok, LLMResult.t()} | {:error, term()}
  defp call_streaming(req, body, headers, stream_to) do
    initial_acc = {SSE.new(), :running}
    streaming_body = Map.put(body, :stream, true)

    result =
      Req.post(req,
        url: "/v1/messages",
        json: streaming_body,
        headers: headers,
        into: fn chunk, {sse_acc, _status} ->
          {events, updated_sse} = SSE.parse_chunk(sse_acc, chunk)

          {final_sse, done?} =
            Enum.reduce_while(events, {updated_sse, false}, fn event, {a, _} ->
              maybe_forward_chunk(event, stream_to)

              case SSE.apply_event(a, event) do
                {:cont, new_acc} -> {:cont, {new_acc, false}}
                {:done, final} -> {:halt, {final, true}}
                {:error, err} ->
                  Logger.warning("[Anthropic SSE] error event received: #{inspect(err)}")
                  {:cont, {a, false}}
              end
            end)

          if done? do
            {:halt, {final_sse, :done}}
          else
            {:cont, {final_sse, :running}}
          end
        end,
        acc: initial_acc
      )

    case result do
      {:ok, %{status: 200, body: {sse_acc, _}}} ->
        {:ok, SSE.to_result(sse_acc)}

      {:ok, %{status: status, body: body_content}} ->
        {:error, parse_api_error(status, body_content)}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @spec maybe_forward_chunk(map(), pid()) :: :ok
  defp maybe_forward_chunk(
         %{"type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => text}},
         pid
       ) do
    send(pid, {:llm_chunk, text})
    :ok
  end

  defp maybe_forward_chunk(_event, _pid), do: :ok

  # ---------------------------------------------------------------------------
  # Private — error normalisation
  # ---------------------------------------------------------------------------

  @spec parse_api_error(pos_integer(), term()) :: term()
  defp parse_api_error(401, _body), do: {:auth_error, "Invalid Anthropic API key"}
  defp parse_api_error(429, _body), do: {:rate_limited, "Anthropic rate limit exceeded"}
  defp parse_api_error(529, _body), do: {:overloaded, "Anthropic API overloaded"}

  defp parse_api_error(status, %{"error" => %{"message" => msg}}) do
    {:api_error, status, msg}
  end

  defp parse_api_error(status, body) do
    {:api_error, status, body}
  end

  # ---------------------------------------------------------------------------
  # Private — configuration
  # ---------------------------------------------------------------------------

  @spec config(atom()) :: term()
  defp config(key) do
    :orquesta
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end

  @spec put_if_present(map(), atom(), term()) :: map()
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
