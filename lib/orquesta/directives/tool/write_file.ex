defmodule Orquesta.Directives.Tool.WriteFile do
  @moduledoc """
  Effect directive: write content to a file within the working directory.

  Creates the file if it doesn't exist, or overwrites if it does.
  Signals `{:tool_result, directive_id, {:ok, path} | {:error, reason}}`
  back to the requesting agent.

  ## Args map

    - `:path`         — file path (absolute or relative to `:working_dir`); required
    - `:content`      — content to write; required
    - `:working_dir`  — sandbox root; required
    - `:create_dirs`  — whether to create parent directories; optional (default: true)

  ## Errors

    - `{:path_escape, path}`    — path escapes working directory
    - `{:write_failed, reason}` — error writing file
  """

  @behaviour Orquesta.DirectiveBehaviour

  @dialyzer {:no_underspecs, ensure_parent_dir: 1}

  alias Orquesta.Directives.Tool.ToolHelper

  @type args :: %{
          required(:path) => String.t(),
          required(:content) => String.t(),
          required(:working_dir) => String.t(),
          optional(:create_dirs) => boolean()
        }

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(%{path: path, content: content, working_dir: working_dir} = args, context)
      when is_binary(path) and is_binary(content) and is_binary(working_dir) do
    result = write_file(working_dir, path, content, Map.get(args, :create_dirs, true))

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

  @spec write_file(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, term()}
  defp write_file(working_dir, path, content, create_dirs) do
    case ToolHelper.safe_path(working_dir, path) do
      {:error, :path_escape} ->
        {:error, {:path_escape, path}}

      {:ok, abs_path} ->
        if create_dirs do
          case ensure_parent_dir(abs_path) do
            :ok -> do_write(abs_path, content)
            {:error, reason} -> {:error, reason}
          end
        else
          do_write(abs_path, content)
        end
    end
  end

  @spec ensure_parent_dir(String.t()) :: :ok | {:error, term()}
  defp ensure_parent_dir(abs_path) do
    parent = Path.dirname(abs_path)

    case File.dir?(parent) do
      true ->
        :ok

      false ->
        case File.mkdir_p(parent) do
          :ok -> :ok
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
  end

  @spec do_write(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp do_write(abs_path, content) do
    case File.write(abs_path, content) do
      :ok -> {:ok, abs_path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end
end
