defmodule Orquesta.Directives.Tool.Search do
  @moduledoc """
  Effect directive: search for a regex pattern in files within the working directory.

  Skips `.git`, `_build`, `deps`, and other common ignore patterns.
  Returns matches in `file:line:content` format that LLMs handle well.

  Signals `{:tool_result, directive_id, {:ok, results} | {:error, reason}}`
  back to the requesting agent.

  ## Args map

    - `:pattern`       — regex pattern to search for; required
    - `:working_dir`  — sandbox root; required
    - `:file_glob`    — glob pattern for files to search; optional (default: "**/*")
    - `:max_results`  — maximum number of results; optional (default: 100)

  ## Output format

  Each match is returned as:
  ```
  path/to/file.ex:42: matching line content
  ```
  """

  @behaviour Orquesta.DirectiveBehaviour

  alias Orquesta.Directives.Tool.ToolHelper

  @default_max_results 100

  @skip_dirs ~w(.git _build deps node_modules .elixir_ls .iex .hex)
  @skip_files ~w(.beam)

  @type args :: %{
          required(:pattern) => String.t(),
          required(:working_dir) => String.t(),
          optional(:file_glob) => String.t(),
          optional(:max_results) => pos_integer()
        }

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(%{pattern: pattern, working_dir: working_dir} = args, context)
      when is_binary(pattern) and is_binary(working_dir) do
    result = search_files(
      working_dir,
      pattern,
      Map.get(args, :file_glob, "**/*"),
      Map.get(args, :max_results, @default_max_results)
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

  @spec search_files(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  defp search_files(working_dir, pattern_str, file_glob, max_results) do
    case Regex.compile(pattern_str) do
      {:ok, pattern} ->
        abs_working = Path.expand(working_dir)

        unless File.dir?(abs_working) do
          {:error, {:working_dir_not_found, working_dir}}
        else
          results = do_search(abs_working, pattern, file_glob, max_results)
          {:ok, format_results(results)}
        end

      {:error, reason} ->
        {:error, {:invalid_regex, reason}}
    end
  end

  @spec do_search(String.t(), Regex.t(), String.t(), pos_integer()) :: [map()]
  defp do_search(abs_working, pattern, file_glob, max_results) do
    Path.wildcard(Path.join(abs_working, file_glob))
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&skip_file?/1)
    |> Enum.flat_map(&search_file(&1, pattern))
    |> Enum.take(max_results)
  end

  @spec skip_file?(String.t()) :: boolean()
  defp skip_file?(path) do
    parts = Path.split(path)

    Enum.any?(@skip_dirs, fn skip ->
      Enum.member?(parts, skip)
    end) or Enum.any?(@skip_files, fn skip ->
      String.ends_with?(path, skip)
    end)
  end

  @spec search_file(String.t(), Regex.t()) :: [map()]
  defp search_file(path, pattern) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(pattern, line) end)
        |> Enum.map(fn {line, line_num} ->
          %{path: path, line: line_num, content: String.trim(line)}
        end)

      {:error, _} ->
        []
    end
  end

  @spec format_results([map()]) :: String.t()
  defp format_results([]) do
    "No matches found."
  end

  defp format_results(results) do
    results
    |> Enum.map(fn %{path: path, line: line_num, content: content} ->
      relative = Path.relative_to(path, Path.dirname(hd(results).path))
      "#{relative}:#{line_num}:#{content}"
    end)
    |> Enum.join("\n")
  end
end
