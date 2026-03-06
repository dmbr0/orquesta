defmodule Orquesta.Directives.Tool.Bash do
  @moduledoc """
  Effect directive: execute a bash command inside a working directory.

  Runs the command with a configurable timeout, captures stdout + stderr,
  and signals `{:tool_result, directive_id, {:ok, output} | {:error, reason}}`
  back to the requesting agent.

  ## Args map

    - `:command`      — shell command string; required
    - `:working_dir`  — absolute path to the sandbox directory; required
    - `:timeout_ms`   — command timeout in milliseconds; optional (default: 30_000)
    - `:env`          — map of extra environment variables; optional

  ## Security

  The command runs inside `:working_dir`. No path escaping is checked for
  the command itself — that is the agent's responsibility. For untrusted
  input, the caller must sanitise the command before constructing args.
  """

  @behaviour Orquesta.DirectiveBehaviour

  alias Orquesta.Directives.Tool.ToolHelper

  @default_timeout_ms 30_000
  @max_output_bytes 65_536

  @type args :: %{
          required(:command) => String.t(),
          required(:working_dir) => String.t(),
          optional(:timeout_ms) => pos_integer(),
          optional(:env) => %{String.t() => String.t()}
        }

  @impl Orquesta.DirectiveBehaviour
  @spec phase() :: Orquesta.Types.phase()
  def phase, do: :effect

  @impl Orquesta.DirectiveBehaviour
  @spec execute(args(), Orquesta.DirectiveBehaviour.execute_context()) ::
          :ok | {:error, term()}
  def execute(%{command: command, working_dir: working_dir} = args, context)
      when is_binary(command) and is_binary(working_dir) do
    timeout_ms = Map.get(args, :timeout_ms, @default_timeout_ms)
    extra_env = Map.get(args, :env, %{})

    result = run_command(command, working_dir, timeout_ms, extra_env)

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

  @spec run_command(String.t(), String.t(), pos_integer(), map()) ::
          {:ok, String.t()} | {:error, term()}
  defp run_command(command, working_dir, timeout_ms, extra_env) do
    unless File.dir?(working_dir) do
      {:error, {:working_dir_not_found, working_dir}}
    else
      port_env =
        extra_env
        |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

      port =
        Port.open(
          {:spawn_executable, System.find_executable("bash")},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:cd, working_dir},
            {:args, ["-c", command]},
            {:env, port_env}
          ]
        )

      collect_output(port, "", timeout_ms)
    end
  end

  @spec collect_output(port(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  defp collect_output(port, acc, timeout_ms) do
    receive do
      {^port, {:data, chunk}} ->
        new_acc = acc <> chunk

        if byte_size(new_acc) > @max_output_bytes do
          Port.close(port)
          truncated = ToolHelper.truncate(new_acc, @max_output_bytes)
          {:ok, truncated}
        else
          collect_output(port, new_acc, timeout_ms)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status, acc}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, {:timeout, timeout_ms}}
    end
  end
end
