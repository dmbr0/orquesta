defmodule Orquesta.Directives.Tool.ReadFile do
  @moduledoc """
  Effect directive: read the contents of a file within the working directory.

  Signals `{:tool_result, directive_id, {:ok, content} | {:error, reason}}`
  back to the requesting agent.

  ## Args map

    - `:path`         — file path (absolute or relative to `:working_dir`); required
    - `:working_dir`  — sandbox root; required
    - `:max_bytes`    — maximum bytes to read; optional (default: 65_536)

  ## Errors

    - `{:path_escape, path}`    — path escapes working directory
    - `{:file_not_found, path}` — file does not exist
    - `{:read_failed, reason}`  — error reading file
  """

  @behaviour Orquesta.DirectiveBehaviour

  alias Orquesta.Directives.Tool.ToolHelper

  @default_max_bytes 65_536

  @type args :: %{
          required(:path) => String.t(),
          required(:working_dir) => String.t(),
          optional(:max_bytes) => pos_integer()
        }

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(%{path: path, working_dir: working_dir} = args, context)
      when is_binary(path) and is_binary(working_dir) do
    result = read_file(working_dir, path, Map.get(args, :max_bytes, @default_max_bytes))

    ToolHelper.signal_result(
      context.agent_instance_id,
      context.directive_id,
      context.correlation_id,
      context.causation_id,
      result
    )
  end

  def execute(args, _context) do
    {:error, {:invalid_args, args}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec read_file(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  defp read_file(working_dir, path, max_bytes) do
    case ToolHelper.safe_path(working_dir, path) do
      {:error, :path_escape} ->
        {:error, {:path_escape, path}}

      {:ok, abs_path} ->
        case File.read(abs_path) do
          {:error, :enoent} ->
            {:error, {:file_not_found, abs_path}}

          {:error, reason} ->
            {:error, {:read_failed, reason}}

          {:ok, content} ->
            truncated = ToolHelper.truncate(content, max_bytes)
            {:ok, truncated}
        end
    end
  end
end
