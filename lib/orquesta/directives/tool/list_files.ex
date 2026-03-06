defmodule Orquesta.Directives.Tool.ListFiles do
  @moduledoc """
  Effect directive: list files and directories within the working directory.

  Returns a tree-style listing similar to the `find` or `tree` command.
  Skips `.git`, `_build`, `deps`, and other common ignore patterns.

  Signals `{:tool_result, directive_id, {:ok, listing} | {:error, reason}}`
  back to the requesting agent.

  ## Args map

    - `:path`         — directory path (absolute or relative to `:working_dir`); optional
    - `:working_dir`  — sandbox root; required
    - `:max_depth`   — maximum depth to recurse; optional (default: 3)
    - `:include_hidden` — whether to include hidden files; optional (default: false)

  ## Output format

  ```
  .
  ├── lib/
  │   └── orquesta.ex
  ├── test/
  │   └── test_helper.exs
  └── mix.exs
  ```
  """

  @behaviour Orquesta.DirectiveBehaviour

  alias Orquesta.Directives.Tool.ToolHelper

  @default_max_depth 3

  @skip_dirs ~w(.git _build deps node_modules .elixir_ls .iex .hex)

  @type args :: %{
          required(:working_dir) => String.t(),
          optional(:path) => String.t(),
          optional(:max_depth) => pos_integer(),
          optional(:include_hidden) => boolean()
        }

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(%{working_dir: working_dir} = args, context)
      when is_binary(working_dir) do
    result = list_files(
      working_dir,
      Map.get(args, :path),
      Map.get(args, :max_depth, @default_max_depth),
      Map.get(args, :include_hidden, false)
    )

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

  @spec list_files(String.t(), String.t() | nil, pos_integer(), boolean()) ::
          {:ok, String.t()} | {:error, term()}
  defp list_files(working_dir, path, max_depth, include_hidden) do
    base_dir = Path.expand(working_dir)

    unless File.dir?(base_dir) do
      {:error, {:working_dir_not_found, working_dir}}
    else
      case resolve_target(working_dir, base_dir, path) do
        {:error, reason} -> {:error, reason}
        target_dir -> {:ok, do_list(target_dir, 0, max_depth, include_hidden)}
      end
    end
  end

  @spec resolve_target(String.t(), String.t(), String.t() | nil) ::
          String.t() | {:error, term()}
  defp resolve_target(_working_dir, base_dir, nil), do: base_dir

  defp resolve_target(working_dir, _base_dir, path) do
    case ToolHelper.safe_path(working_dir, path) do
      {:ok, abs} -> abs
      {:error, :path_escape} -> {:error, {:path_escape, path}}
    end
  end

  @spec do_list(String.t(), non_neg_integer(), pos_integer(), boolean()) :: String.t()
  defp do_list(dir, current_depth, max_depth, include_hidden) do
    {dirs, files} = list_dir_entries(dir, include_hidden)
    root = if current_depth == 0, do: ["."], else: [Path.basename(dir)]
    nested = collect_nested(dirs, dir, current_depth, max_depth, include_hidden)
    format_listing(root ++ nested ++ files, current_depth)
  end

  @spec list_dir_entries(String.t(), boolean()) :: {[String.t()], [String.t()]}
  defp list_dir_entries(dir, include_hidden) do
    entries =
      case File.ls(dir) do
        {:ok, files} -> files
        {:error, _} -> []
      end
      |> Enum.reject(&(not include_hidden and String.starts_with?(&1, ".")))
      |> Enum.reject(&skip_dir?/1)
      |> Enum.sort()

    Enum.split_with(entries, &File.dir?(Path.join(dir, &1)))
  end

  @spec collect_nested(
          [String.t()],
          String.t(),
          non_neg_integer(),
          pos_integer(),
          boolean()
        ) :: [String.t()]
  defp collect_nested(dirs, dir, current_depth, max_depth, include_hidden) do
    if current_depth < max_depth do
      Enum.flat_map(dirs, fn d ->
        nested = Path.join(dir, d)

        if File.dir?(nested) do
          [d, do_list(nested, current_depth + 1, max_depth, include_hidden)]
        else
          []
        end
      end)
    else
      Enum.map(dirs, &"#{&1}/")
    end
  end

  @spec format_listing([String.t()], non_neg_integer()) :: String.t()
  defp format_listing(parts, 0) do
    Enum.join(parts, "\n")
  end

  defp format_listing(parts, depth) do
    prefix = String.duplicate("│   ", depth)

    Enum.map_join(parts, "\n#{prefix}├── ", fn
      s when is_binary(s) -> s
      list -> Enum.join(list, "\n#{prefix}│   ├── ")
    end)
  end

  @spec skip_dir?(String.t()) :: boolean()
  defp skip_dir?(name) do
    Enum.member?(@skip_dirs, name)
  end
end
