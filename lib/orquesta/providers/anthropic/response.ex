defmodule Orquesta.Providers.Anthropic.Response do
  @moduledoc """
  Normalised response structs from the Anthropic API.

  Both the streaming and non-streaming code paths in
  `Orquesta.Providers.Anthropic` produce the same `%LLMResult{}`.
  The rest of the system never needs to know how the call was made.
  """

  # ---------------------------------------------------------------------------
  # Content block types
  # ---------------------------------------------------------------------------

  defmodule TextBlock do
    @moduledoc "A text content block returned by Claude."

    @type t :: %__MODULE__{text: String.t()}

    @enforce_keys [:text]
    defstruct [:text]
  end

  defmodule ToolUseBlock do
    @moduledoc "A tool use request block returned by Claude."

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            input: map()
          }

    @enforce_keys [:id, :name, :input]
    defstruct [:id, :name, :input]
  end

  # ---------------------------------------------------------------------------
  # LLMResult
  # ---------------------------------------------------------------------------

  defmodule LLMResult do
    @moduledoc """
    Normalised result from any LLM call — streaming or blocking.

    `content` is a list of `%TextBlock{}` and/or `%ToolUseBlock{}`.
    When `stop_reason` is `:tool_use`, the caller should execute
    the tool calls and continue the conversation.
    """

    alias Orquesta.Providers.Anthropic.Response

    @type t :: %__MODULE__{
            id: String.t() | nil,
            model: String.t() | nil,
            stop_reason: atom() | nil,
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            content: [Response.TextBlock.t() | Response.ToolUseBlock.t()]
          }

    defstruct [
      :id,
      :model,
      :stop_reason,
      input_tokens: 0,
      output_tokens: 0,
      content: []
    ]

    @doc "Returns all text content joined as a single string."
    @spec text(t()) :: String.t()
    def text(%__MODULE__{content: content}) do
      content
      |> Enum.filter(&match?(%Response.TextBlock{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join("")
    end

    @doc "Returns all tool use request blocks."
    @spec tool_calls(t()) :: [Response.ToolUseBlock.t()]
    def tool_calls(%__MODULE__{content: content}) do
      Enum.filter(content, &match?(%Response.ToolUseBlock{}, &1))
    end

    @doc "Returns true if Claude is requesting tool use."
    @spec wants_tools?(t()) :: boolean()
    def wants_tools?(%__MODULE__{stop_reason: :tool_use}), do: true
    def wants_tools?(%__MODULE__{}), do: false
  end

  # ---------------------------------------------------------------------------
  # Public type aliases (used in specs elsewhere)
  # ---------------------------------------------------------------------------

  @type text_block :: TextBlock.t()
  @type tool_use_block :: ToolUseBlock.t()

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses a raw Anthropic API response body (already JSON-decoded) into
  `{:ok, %LLMResult{}}` or `{:error, reason}`.

  Used by the non-streaming code path.
  """
  @spec parse(map()) :: {:ok, LLMResult.t()} | {:error, term()}
  def parse(%{
        "id" => id,
        "model" => model,
        "stop_reason" => stop_reason,
        "content" => content,
        "usage" => usage
      }) do
    result = %LLMResult{
      id: id,
      model: model,
      stop_reason: parse_stop_reason(stop_reason),
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      content: Enum.map(content, &parse_block/1)
    }

    {:ok, result}
  end

  def parse(response) do
    {:error, {:unexpected_response_shape, response}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec parse_block(map()) :: TextBlock.t() | ToolUseBlock.t()
  defp parse_block(%{"type" => "text", "text" => text}) do
    %TextBlock{text: text}
  end

  defp parse_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %ToolUseBlock{id: id, name: name, input: input}
  end

  @spec parse_stop_reason(String.t() | nil) :: atom() | nil
  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("stop_sequence"), do: :stop_sequence
  defp parse_stop_reason(nil), do: nil
  defp parse_stop_reason(other), do: {:unknown, other}
end
