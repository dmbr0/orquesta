defmodule Orquesta.Providers.Anthropic.SSE do
  @moduledoc """
  Stateful accumulator for Anthropic's Server-Sent Event streaming format.

  Anthropic streams newline-delimited JSON events over a chunked HTTP
  response. A single chunk may contain multiple complete events, or a
  single event may be split across multiple chunks. This module handles
  both cases via an internal binary buffer.

  ## Usage

      acc = SSE.new()

      # For each raw chunk from the HTTP stream:
      {events, acc} = SSE.parse_chunk(acc, chunk)

      # Apply each event to advance accumulator state:
      Enum.reduce_while(events, {:cont, acc}, fn event, {:cont, a} ->
        case SSE.apply_event(a, event) do
          {:cont, new_acc}  -> {:cont, {:cont, new_acc}}
          {:done, final}    -> {:halt, {:done, final}}
          {:error, err}     -> {:halt, {:error, err}}
        end
      end)

  When `apply_event/2` returns `{:done, acc}`, call `SSE.to_result/1`
  to obtain the final `%LLMResult{}`.
  """

  alias Orquesta.Providers.Anthropic.Response

  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: String.t() | nil,
          content: [Response.text_block() | Response.tool_use_block()],
          stop_reason: atom() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          current_block: map() | nil,
          buffer: binary()
        }

  defstruct [
    :id,
    :model,
    :stop_reason,
    :current_block,
    content: [],
    input_tokens: 0,
    output_tokens: 0,
    buffer: ""
  ]

  @doc "Returns a new, empty SSE accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Parses a raw binary chunk from the HTTP stream.

  Returns `{events, updated_accumulator}` where events is a list of decoded
  JSON maps. Multiple events may be returned per chunk; the accumulator
  retains any incomplete trailing data in its buffer.
  """
  @spec parse_chunk(t(), binary()) :: {[map()], t()}
  def parse_chunk(%__MODULE__{buffer: buf} = acc, chunk) when is_binary(chunk) do
    full = buf <> chunk
    {complete_raw, remainder} = split_on_double_newline(full)

    events =
      complete_raw
      |> Enum.map(&extract_data_json/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&decode_json/1)

    {events, %{acc | buffer: remainder}}
  end

  @doc """
  Applies a single parsed event map to the accumulator.

  Returns one of:
  - `{:cont, updated_acc}` — more events expected
  - `{:done, final_acc}`   — `message_stop` received; call `to_result/1`
  - `{:error, error_map}`  — Anthropic returned an error event
  """
  @spec apply_event(t(), map()) :: {:cont, t()} | {:done, t()} | {:error, map()}
  def apply_event(%__MODULE__{} = acc, %{"type" => "message_start", "message" => msg}) do
    {:cont, %{acc |
      id: msg["id"],
      model: msg["model"],
      input_tokens: get_in(msg, ["usage", "input_tokens"]) || 0
    }}
  end

  def apply_event(%__MODULE__{} = acc, %{"type" => "content_block_start", "content_block" => block}) do
    {:cont, %{acc | current_block: init_block(block)}}
  end

  def apply_event(%__MODULE__{} = acc, %{"type" => "content_block_delta", "delta" => delta}) do
    {:cont, apply_delta(acc, delta)}
  end

  def apply_event(%__MODULE__{} = acc, %{"type" => "content_block_stop"}) do
    finalised = finalise_block(acc.current_block)
    {:cont, %{acc | content: acc.content ++ [finalised], current_block: nil}}
  end

  def apply_event(%__MODULE__{} = acc, %{"type" => "message_delta", "delta" => delta} = event) do
    usage = event["usage"] || %{}
    {:cont, %{acc |
      stop_reason: parse_stop_reason(delta["stop_reason"]),
      output_tokens: usage["output_tokens"] || acc.output_tokens
    }}
  end

  def apply_event(%__MODULE__{} = acc, %{"type" => "message_stop"}) do
    {:done, acc}
  end

  def apply_event(%__MODULE__{}, %{"type" => "error", "error" => err}) do
    {:error, err}
  end

  # ping or unknown event types — safe to ignore
  def apply_event(%__MODULE__{} = acc, _event) do
    {:cont, acc}
  end

  @doc "Converts a completed accumulator to a `%LLMResult{}`."
  @spec to_result(t()) :: Response.LLMResult.t()
  def to_result(%__MODULE__{} = acc) do
    %Response.LLMResult{
      id: acc.id,
      model: acc.model,
      stop_reason: acc.stop_reason,
      input_tokens: acc.input_tokens,
      output_tokens: acc.output_tokens,
      content: Enum.map(acc.content, &to_response_block/1)
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec split_on_double_newline(binary()) :: {[binary()], binary()}
  defp split_on_double_newline(buffer) do
    parts = String.split(buffer, "\n\n")

    case parts do
      [only] ->
        {[], only}

      _ ->
        {remainder, complete} = List.pop_at(parts, -1)
        non_empty = Enum.reject(complete, &(&1 == ""))
        {non_empty, remainder}
    end
  end

  @spec extract_data_json(binary()) :: binary() | nil
  defp extract_data_json(raw_event) do
    raw_event
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "data: ", parts: 2) do
        [_, json] -> json
        _ -> nil
      end
    end)
  end

  @spec decode_json(binary()) :: [map()]
  defp decode_json("[DONE]"), do: []

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, parsed} -> [parsed]
      {:error, _} -> []
    end
  end

  @spec init_block(map()) :: map()
  defp init_block(%{"type" => "text"}), do: %{type: :text, text: ""}

  defp init_block(%{"type" => "tool_use", "id" => id, "name" => name}) do
    %{type: :tool_use, id: id, name: name, input_json: ""}
  end

  defp init_block(block), do: %{type: :unknown, raw: block}

  @spec apply_delta(t(), map()) :: t()
  defp apply_delta(%__MODULE__{current_block: %{type: :text} = block} = acc,
                   %{"type" => "text_delta", "text" => text}) do
    %{acc | current_block: %{block | text: block.text <> text}}
  end

  defp apply_delta(%__MODULE__{current_block: %{type: :tool_use} = block} = acc,
                   %{"type" => "input_json_delta", "partial_json" => partial}) do
    %{acc | current_block: %{block | input_json: block.input_json <> partial}}
  end

  defp apply_delta(acc, _delta), do: acc

  @spec finalise_block(map()) :: map()
  defp finalise_block(%{type: :tool_use, input_json: json} = block) do
    parsed =
      case Jason.decode(json) do
        {:ok, input} -> input
        {:error, _} -> %{}
      end

    %{block | input_json: parsed}
  end

  defp finalise_block(block), do: block

  @spec to_response_block(map()) :: Response.TextBlock.t() | Response.ToolUseBlock.t()
  defp to_response_block(%{type: :text, text: text}) do
    %Response.TextBlock{text: text}
  end

  defp to_response_block(%{type: :tool_use, id: id, name: name, input_json: input}) do
    %Response.ToolUseBlock{id: id, name: name, input: input}
  end

  @spec parse_stop_reason(String.t() | nil) :: atom() | nil
  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("stop_sequence"), do: :stop_sequence
  defp parse_stop_reason(nil), do: nil
  defp parse_stop_reason(other), do: {:unknown, other}
end
