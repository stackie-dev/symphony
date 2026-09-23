defmodule SymphonyElixir.Workspace.Retention do
  @moduledoc """
  Owns the single local and remote workspace retention decision.

  It deletes only a path-safe, clean Git checkout whose HEAD has no commits ahead of its upstream,
  after a successful before-remove hook and a second verification; unknown state is retained.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Workspace.{Context, Hooks, Paths, Remote}

  @type worker_host :: String.t() | nil
  @type removal_result :: {:ok, [String.t()]} | {:error, term(), String.t()}

  @absent_marker "__SYMPHONY_RETENTION_ABSENT__"
  @safe_marker "__SYMPHONY_RETENTION_SAFE__"
  @removed_marker "__SYMPHONY_RETENTION_REMOVED__"

  @spec remove(Path.t()) :: removal_result()
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: removal_result()
  def remove(workspace, worker_host) when is_binary(workspace) do
    with :ok <- Paths.validate_workspace_path(workspace, worker_host),
         {:ok, :safe} <- inspect_workspace(workspace, worker_host),
         :ok <- Hooks.run_before_remove_hook(workspace, %{identifier: Path.basename(workspace)}, worker_host),
         {:ok, :removed} <- run_safe_action(workspace, worker_host, :remove) do
      {:ok, []}
    else
      {:ok, :absent} ->
        {:ok, []}

      {:error, reason} ->
        log_retained_workspace(workspace, worker_host, reason)
        {:error, reason, ""}

      {:error, reason, _output} = error ->
        log_retained_workspace(workspace, worker_host, reason)
        error
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: removal_result()
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case Paths.validate_recorded_workspace_path(workspace) do
        :ok -> remove_with_root(workspace, Path.dirname(workspace), nil)
        {:error, reason} -> {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host),
    do: remove(workspace, worker_host)

  def remove_recorded(workspace, _worker_host),
    do: {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok | {:error, term()}
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host) do
    remove_identifier(issue, worker_host)
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier),
    do: remove_identifier(identifier, worker_host)

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  defp remove_identifier(identifier, worker_host) when is_binary(worker_host) do
    remove_identifier_on_host(identifier, worker_host)
  end

  defp remove_identifier(identifier, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] -> remove_identifier_on_host(identifier, nil)
      worker_hosts -> Enum.map(worker_hosts, &remove_identifier_on_host(identifier, &1)) |> collect_results()
    end
  end

  defp remove_identifier_on_host(identifier, worker_host) do
    case Paths.workspace_path_for_issue(Paths.workspace_key(identifier), worker_host) do
      {:ok, workspace} -> result_to_cleanup_result(remove(workspace, worker_host))
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_results(results) do
    failures = Enum.reject(results, &(&1 == :ok))
    if failures == [], do: :ok, else: {:error, {:workspace_cleanup_failed, failures}}
  end

  defp result_to_cleanup_result({:ok, _removed}), do: :ok
  defp result_to_cleanup_result({:error, reason, output}), do: {:error, {reason, output}}

  defp remove_with_root(workspace, workspace_root, worker_host) do
    with {:ok, :safe} <- inspect_workspace(workspace, worker_host, workspace_root),
         :ok <- Hooks.run_before_remove_hook(workspace, %{identifier: Path.basename(workspace)}, worker_host),
         {:ok, :removed} <- run_safe_action(workspace, worker_host, :remove, workspace_root) do
      {:ok, []}
    else
      {:ok, :absent} ->
        {:ok, []}

      {:error, reason} ->
        log_retained_workspace(workspace, worker_host, reason)
        {:error, reason, ""}

      {:error, reason, _output} = error ->
        log_retained_workspace(workspace, worker_host, reason)
        error
    end
  end

  defp inspect_workspace(workspace, worker_host, workspace_root \\ nil) do
    case run_safe_action(workspace, worker_host, :inspect, workspace_root) do
      {:ok, :safe} = result ->
        result

      {:ok, :absent} = result ->
        result

      {:error, reason, output} ->
        {:error, {reason, output}}
    end
  end

  defp run_safe_action(workspace, worker_host, action, workspace_root \\ nil) do
    root = workspace_root || configured_workspace_root(worker_host)
    script = retention_script(workspace, root, action)

    result =
      case worker_host do
        nil -> {:ok, System.cmd("sh", ["-c", script], stderr_to_stdout: true)}
        host -> Remote.run_command(host, script, Config.settings!().hooks.timeout_ms)
      end

    decode_result(result, action, worker_host)
  rescue
    error in [ArgumentError, ErlangError, File.Error] ->
      {:error, {:workspace_inspection_failed, Exception.message(error)}, ""}
  end

  defp configured_workspace_root(nil), do: Config.local_workspace_root()
  defp configured_workspace_root(_worker_host), do: Config.settings!().workspace.root

  defp retention_script(workspace, workspace_root, action) do
    ([
       "set -eu",
       "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR",
       Paths.remote_shell_assign("workspace", workspace),
       Paths.remote_shell_assign("workspace_root", workspace_root)
     ] ++ verification_lines() ++ [final_action(action)])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp verification_lines do
    [
      "if [ ! -e \"$workspace\" ] && [ ! -L \"$workspace\" ]; then printf '%s\\n' '#{@absent_marker}'; exit 0; fi",
      "if [ -L \"$workspace\" ] || [ ! -d \"$workspace\" ]; then printf '%s\\n' 'retained:unsafe_path' >&2; exit 20; fi",
      "if [ ! -d \"$workspace_root\" ]; then printf '%s\\n' 'inspection_failed:workspace_root_missing' >&2; exit 21; fi",
      "if [ ! -d \"$workspace/.git\" ] || [ -L \"$workspace/.git\" ]; then printf '%s\\n' 'retained:unknown_git_ownership' >&2; exit 20; fi",
      "if ! workspace_root_real=$(cd \"$workspace_root\" && pwd -P); then printf '%s\\n' 'inspection_failed:workspace_root_unreadable' >&2; exit 21; fi",
      "if ! workspace_parent_real=$(cd \"$(dirname \"$workspace\")\" && pwd -P); then printf '%s\\n' 'inspection_failed:workspace_parent_unreadable' >&2; exit 21; fi",
      "if ! workspace_real=$(cd \"$workspace\" && pwd -P); then printf '%s\\n' 'inspection_failed:workspace_unreadable' >&2; exit 21; fi",
      "workspace_expected=\"$workspace_root_real/$(basename \"$workspace\")\"",
      "if [ \"$workspace_parent_real\" != \"$workspace_root_real\" ] || [ \"$workspace_real\" != \"$workspace_expected\" ]; then printf '%s\\n' 'retained:path_not_direct_child' >&2; exit 20; fi",
      "if ! git_top=$(git -C \"$workspace\" rev-parse --show-toplevel 2>/dev/null); then printf '%s\\n' 'inspection_failed:git_root_unreadable' >&2; exit 21; fi",
      "if [ \"$git_top\" != \"$workspace_real\" ]; then printf '%s\\n' 'retained:git_root_mismatch' >&2; exit 20; fi",
      "if ! git -C \"$workspace\" remote get-url origin >/dev/null 2>&1; then printf '%s\\n' 'retained:unknown_origin' >&2; exit 20; fi",
      "if ! git -C \"$workspace\" symbolic-ref -q HEAD >/dev/null 2>&1; then printf '%s\\n' 'retained:detached_head' >&2; exit 20; fi",
      "if ! git -C \"$workspace\" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then printf '%s\\n' 'retained:unknown_upstream' >&2; exit 20; fi",
      "if ! unique_commits=$(git -C \"$workspace\" rev-list --count '@{upstream}..HEAD' 2>/dev/null); then printf '%s\\n' 'inspection_failed:commit_history_unreadable' >&2; exit 21; fi",
      "if [ \"$unique_commits\" -ne 0 ]; then printf '%s\\n' 'retained:unique_commits' >&2; exit 20; fi",
      "if ! worktree_status=$(git -C \"$workspace\" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null); then printf '%s\\n' 'inspection_failed:worktree_unreadable' >&2; exit 21; fi",
      "if [ -n \"$worktree_status\" ]; then printf '%s\\n' 'retained:working_tree_changes' >&2; exit 20; fi"
    ]
  end

  defp final_action(:inspect), do: "printf '%s\\n' '#{@safe_marker}'"
  defp final_action(:remove), do: "rm -rf \"$workspace\"; printf '%s\\n' '#{@removed_marker}'"

  defp decode_result({:ok, {output, 0}}, action, _worker_host) do
    text = IO.iodata_to_binary(output)
    lines = text |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    cond do
      @absent_marker in lines -> {:ok, :absent}
      action == :inspect and @safe_marker in lines -> {:ok, :safe}
      action == :remove and @removed_marker in lines -> {:ok, :removed}
      true -> {:error, {:workspace_inspection_failed, :invalid_output}, text}
    end
  end

  defp decode_result({:ok, {output, 20}}, _action, _worker_host) do
    text = output |> IO.iodata_to_binary() |> String.trim()
    {:error, {:workspace_retained, text}, text}
  end

  defp decode_result({:ok, {output, status}}, _action, worker_host) do
    text = IO.iodata_to_binary(output)
    {:error, {:workspace_inspection_failed, worker_host, status}, text}
  end

  defp decode_result({:error, reason}, _action, _worker_host),
    do: {:error, {:workspace_inspection_failed, reason}, ""}

  defp log_retained_workspace(workspace, worker_host, reason) do
    Logger.warning("Keeping workspace because safe removal was not proven path=#{workspace} worker_host=#{Context.worker_host_for_log(worker_host)} reason=#{inspect(reason)}")
  end
end
