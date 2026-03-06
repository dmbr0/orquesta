defmodule Orquesta.Directives.Tool.ToolHelper do
  @moduledoc """
  Shared helpers for tool directives.

  All tool directives follow the same pattern:
    1. Execute an operation (bash, file I/O, etc.)
    2. Signal the result back to the requesting agent as
       `{:tool_result, directive_id, {:ok, output} | {:error, reason}}`

  Path security: every tool that touches the filesystem accepts a
  `working_dir` in its args. `safe_path/2` resolves the target path
  and rejects anything that escapes the working directory.
  """

  require Logger

  alias Orquesta.Runtime.AgentRuntime
  alias Orquesta.Signal

  @doc """
  Signals a tool result back to the originating agent.

  The agent handles `{:tool_result, directive_id, result}` in a subsequent
  `cmd/2` call. The `directive_id` lets the agent correlate which tool call
  a result belongs to when multiple are outstanding.
  """
  @spec signal_result(
          agent_instance_id :: String.t(),
          directive_id :: String.t(),
          correlation_id :: String.t(),
          causation_id :: String.t() | nil,
          result :: {:ok, term()} | {:error, term()}
        ) :: :ok | {:error, term()}
  def signal_result(agent_instance_id, directive_id, correlation_id, causation_id, result) do
    signal =
      Signal.new(
        agent_instance_id,
        {:tool_result, directive_id, result},
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
          "[Tool] failed to signal result to agent #{agent_instance_id}: #{inspect(e)}"
        )

        {:error, {:signal_failed, e}}
    end
  end

  @doc """
  Resolves `path` relative to `working_dir` and verifies it does not escape.

  Returns `{:ok, absolute_path}` if safe, `{:error, :path_escape}` otherwise.
  Symlinks are NOT followed — callers should use the returned path directly.
  """
  @spec safe_path(working_dir :: String.t(), path :: String.t()) ::
          {:ok, String.t()} | {:error, :path_escape}
  def safe_path(working_dir, path) when is_binary(working_dir) and is_binary(path) do
    abs_working = Path.expand(working_dir)

    resolved =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, abs_working)
      end

    if String.starts_with?(resolved, abs_working <> "/") or resolved == abs_working do
      {:ok, resolved}
    else
      {:error, :path_escape}
    end
  end

  @doc "Truncates output to a safe length to avoid flooding agent state."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(output, max_bytes \\ 65_536) when is_binary(output) do
    if byte_size(output) > max_bytes do
      truncated = binary_part(output, 0, max_bytes)
      truncated <> "\n[... truncated at #{max_bytes} bytes ...]"
    else
      output
    end
  end
end
