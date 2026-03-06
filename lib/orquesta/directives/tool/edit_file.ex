defmodule Orquesta.Directives.Tool.EditFile do
  @moduledoc """
  Effect directive: replace an exact string in a file within the working directory.

  The `old_str` must appear exactly once in the file. This uniqueness
  requirement prevents ambiguous edits — if the string appears zero or
  multiple times, the directive returns an error rather than guessing.

  Signals `{:tool_result, directive_id, {:ok, path} | {:error, reason}}`
  back to the requesting agent.

  ## Args map

    - `:path`         — file path (absolute or relative to `:working_dir`); required
    - `:old_str`      — exact string to replace; must appear exactly once; required
    - `:new_str`      — replacement string; required (may be empty to delete)
    - `:working_dir`  — sandbox root; required

  ## Errors

    - `{:not_found, old_str}`       — string not found in file
    - `{:ambiguous, count, old_str}`— string appears more than once
    - `{:path_escape, path}`        — path escapes working directory
    - `{:file_not_found, path}`     — file does not exist
  """

  @behaviour Orquesta.DirectiveBehaviour

  alias Orquesta.Directives.Tool.ToolHelper

  @type args :: %{
          required(:path) => String.t(),
          required(:old_str) => String.t(),
          required(:new_str) => String.t(),
          required(:working_dir) => String.t()
        }

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(
        %{path: path, old_str: old_str, new_str: new_str, working_dir: working_dir},
        context
      )
      when is_binary(path) and is_binary(old_str) and is_binary(new_str) and
             is_binary(working_dir) do
    result = edit_file(working_dir, path, old_str, new_str)

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

  @spec edit_file(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp edit_file(working_dir, path, old_str, new_str) do
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
            count = count_occurrences(content, old_str)

            cond do
              count == 0 ->
                {:error, {:not_found, old_str}}

              count > 1 ->
                {:error, {:ambiguous, count, old_str}}

              true ->
                updated = String.replace(content, old_str, new_str, global: false)

                case File.write(abs_path, updated) do
                  :ok -> {:ok, abs_path}
                  {:error, reason} -> {:error, {:write_failed, reason}}
                end
            end
        end
    end
  end

  @spec count_occurrences(String.t(), String.t()) :: non_neg_integer()
  defp count_occurrences(haystack, needle) when is_binary(haystack) and is_binary(needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end
