defmodule SymphonyElixir.Workspace.Creation do
  @moduledoc """
  Creates or resumes the deterministic issue workspace and runs creation hooks.

  Existing directories are reused; failed hooks leave a private retry marker beside their partial work.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Workspace.{Context, Hooks, Paths, Remote}

  @type worker_host :: String.t() | nil
  @type issue_ref :: map() | String.t() | nil

  @pending_marker_name ".symphony-after-create-pending"
  @pending_marker_content "symphony-after-create-pending:v1"

  @spec create_for_issue(issue_ref()) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier), do: create_for_issue(issue_or_identifier, nil)

  @spec create_for_issue(issue_ref(), worker_host()) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host) do
    issue_context = Context.issue_context(issue_or_identifier)

    try do
      with workspace_key <- Paths.workspace_key(issue_or_identifier),
           {:ok, workspace} <- Paths.workspace_path_for_issue(workspace_key, worker_host),
           :ok <- Paths.validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        with :ok <- clear_pending_marker(workspace, created?, worker_host) do
          case after_create(workspace, issue_context, created?, worker_host) do
            :ok ->
              {:ok, workspace}

            {:error, _reason} = error ->
              preserve_failed_bootstrap(workspace, worker_host, created?, error)
          end
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{Context.issue_log_context(issue_context)} worker_host=#{Context.worker_host_for_log(worker_host)} error=#{Exception.message(error)}")

        {:error, error}
    end
  end

  defp after_create(workspace, issue_context, created?, worker_host) do
    Hooks.run_after_create_hook(workspace, issue_context, created?, worker_host)
  end

  defp preserve_failed_bootstrap(_workspace, _worker_host, false, error), do: error

  defp preserve_failed_bootstrap(workspace, worker_host, true, hook_error) do
    case write_pending_marker(workspace, worker_host) do
      :ok -> hook_error
      {:error, reason} -> {:error, {:workspace_retry_marker_failed, reason, hook_error}}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, pending_marker?(workspace)}

      File.exists?(workspace) or symlink?(workspace) ->
        {:error, {:workspace_path_not_directory, workspace}}

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        Paths.remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ] && [ ! -L \"$workspace\" ]; then",
        "  if [ -f \"$workspace/#{@pending_marker_name}\" ] && [ ! -L \"$workspace/#{@pending_marker_name}\" ] && [ \"$(cat \"$workspace/#{@pending_marker_name}\")\" = '#{@pending_marker_content}' ]; then created=1; else created=0; fi",
        "elif [ -e \"$workspace\" ] || [ -L \"$workspace\" ]; then",
        "  printf '%s\\n' 'workspace_path_not_directory' >&2",
        "  exit 20",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.join("\n")

    case Remote.run_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> Paths.parse_remote_workspace_output(output)
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
    |> case do
      {:ok, workspace_path, created?} -> {:ok, workspace_path, created?}
      {:error, _reason} = error -> error
    end
  end

  defp create_workspace(workspace) do
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp pending_marker?(workspace) do
    marker = Path.join(workspace, @pending_marker_name)

    case File.lstat(marker) do
      {:ok, %File.Stat{type: :regular}} -> File.read(marker) == {:ok, @pending_marker_content}
      _ -> false
    end
  end

  defp clear_pending_marker(_workspace, false, _worker_host), do: :ok

  defp clear_pending_marker(workspace, true, nil) do
    marker = Path.join(workspace, @pending_marker_name)
    if pending_marker?(workspace), do: File.rm(marker), else: :ok
  end

  defp clear_pending_marker(workspace, true, worker_host) when is_binary(worker_host) do
    script =
      [
        Paths.remote_shell_assign("workspace", workspace),
        "marker=\"$workspace/#{@pending_marker_name}\"",
        "if [ -f \"$marker\" ] && [ ! -L \"$marker\" ] && [ \"$(cat \"$marker\")\" = '#{@pending_marker_content}' ]; then rm -f \"$marker\"; fi"
      ]
      |> Enum.join("\n")

    case Remote.run_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_retry_marker_clear_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_pending_marker(workspace, nil) do
    marker = Path.join(workspace, @pending_marker_name)

    case File.lstat(marker) do
      {:ok, %File.Stat{type: :symlink}} ->
        Logger.warning("Could not record after_create retry because marker is a symlink path=#{marker}")
        {:error, {:unsafe_retry_marker, marker}}

      {:ok, %File.Stat{type: :directory}} ->
        Logger.warning("Could not record after_create retry because marker is a directory path=#{marker}")
        {:error, {:unsafe_retry_marker, marker}}

      {:ok, %File.Stat{type: :regular}} ->
        write_marker(marker)

      {:error, :enoent} ->
        write_marker(marker)

      {:error, reason} ->
        Logger.warning("Could not inspect after_create retry marker path=#{marker} reason=#{inspect(reason)}")
        {:error, reason}

      {:ok, _stat} ->
        Logger.warning("Could not record after_create retry because marker is not a regular file path=#{marker}")
        {:error, {:unsafe_retry_marker, marker}}
    end
  end

  defp write_pending_marker(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        Paths.remote_shell_assign("workspace", workspace),
        "marker=\"$workspace/#{@pending_marker_name}\"",
        "if [ -L \"$marker\" ] || { [ -e \"$marker\" ] && [ ! -f \"$marker\" ]; }; then exit 21; fi",
        "printf '%s\\n' '#{@pending_marker_content}' > \"$marker\""
      ]
      |> Enum.join("\n")

    case Remote.run_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning("Could not record after_create retry worker_host=#{worker_host} status=#{status} output=#{inspect(output)}")
        {:error, {:remote_retry_marker_write_failed, worker_host, status, output}}

      {:error, reason} ->
        Logger.warning("Could not record after_create retry worker_host=#{worker_host} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp write_marker(marker) do
    case File.write(marker, @pending_marker_content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not record after_create retry path=#{marker} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end
end
