defmodule SymphonyElixir.Workspace.Hooks do
  @moduledoc """
  Executes workspace lifecycle hooks and reports failures to their owner.

  A failed before-remove hook is preserved as an error; after-run failures remain best effort.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Workspace.{Context, Paths, Remote}

  @type worker_host :: String.t() | nil
  @type issue_ref :: map() | String.t() | nil

  @spec run_after_create_hook(Path.t(), issue_ref(), boolean(), worker_host()) :: :ok | {:error, term()}
  def run_after_create_hook(_workspace, _issue, false, _worker_host), do: :ok

  def run_after_create_hook(workspace, issue, true, worker_host) do
    case Config.settings!().hooks.after_create do
      nil -> :ok
      command -> run_hook(command, workspace, Context.issue_context(issue), "after_create", worker_host)
    end
  end

  @spec run_before_run_hook(Path.t(), issue_ref(), worker_host()) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue, worker_host) when is_binary(workspace) do
    case Config.settings!().hooks.before_run do
      nil -> :ok
      command -> run_hook(command, workspace, Context.issue_context(issue), "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), issue_ref(), worker_host()) :: :ok
  def run_after_run_hook(workspace, issue, worker_host) when is_binary(workspace) do
    case Config.settings!().hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, Context.issue_context(issue), "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  @spec run_before_remove_hook(Path.t(), issue_ref(), worker_host()) :: :ok | {:error, term()}
  def run_before_remove_hook(workspace, issue, worker_host) do
    case Config.settings!().hooks.before_remove do
      nil -> :ok
      command -> run_hook(command, workspace, Context.issue_context(issue), "before_remove", worker_host)
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    log_hook_start(hook_name, issue_context, workspace, nil)
    script = "cd #{Paths.shell_escape(workspace)} && #{command}"
    task = Task.async(fn -> System.cmd("sh", ["-lc", script], cd: workspace, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        handle_hook_command_result(result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)
        log_hook_timeout(hook_name, issue_context, workspace, nil, timeout_ms)
        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host)
       when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    log_hook_start(hook_name, issue_context, workspace, worker_host)

    script =
      [
        Paths.remote_shell_assign("workspace", workspace),
        "cd \"$workspace\" && #{command}"
      ]
      |> Enum.join("\n")

    case Remote.run_command(worker_host, script, timeout_ms) do
      {:ok, result} ->
        handle_hook_command_result(result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, "remote_command", _timeout_ms}} ->
        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_context, _hook_name), do: :ok

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{Context.issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    if byte_size(binary_output) <= max_bytes do
      binary_output
    else
      binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp log_hook_start(hook_name, issue_context, workspace, worker_host) do
    Logger.info("Running workspace hook hook=#{hook_name} #{Context.issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)}")
  end

  defp log_hook_timeout(hook_name, issue_context, workspace, worker_host, timeout_ms) do
    Logger.warning(
      "Workspace hook timed out hook=#{hook_name} #{Context.issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)} timeout_ms=#{timeout_ms}"
    )
  end
end
