defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Public API for per-issue workspace creation, hooks, paths, and cleanup.

  Retention decisions are delegated to one policy owner; unverified workspace data is preserved.
  """

  alias SymphonyElixir.Workspace.{Creation, Hooks, Paths, Retention}

  @type worker_host :: String.t() | nil
  @type issue_ref :: map() | String.t() | nil
  @type removal_result :: {:ok, [String.t()]} | {:error, term(), String.t()}

  @spec create_for_issue(issue_ref()) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue), do: Creation.create_for_issue(issue)

  @spec create_for_issue(issue_ref(), worker_host()) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue, worker_host), do: Creation.create_for_issue(issue, worker_host)

  @spec remove(Path.t()) :: removal_result()
  def remove(workspace), do: Retention.remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: removal_result()
  def remove(workspace, worker_host), do: Retention.remove(workspace, worker_host)

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: removal_result()
  def remove_recorded(workspace, worker_host), do: Retention.remove_recorded(workspace, worker_host)

  @spec remove_issue_workspaces(term()) :: :ok | {:error, term()}
  def remove_issue_workspaces(identifier), do: Retention.remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok | {:error, term()}
  def remove_issue_workspaces(identifier, worker_host),
    do: Retention.remove_issue_workspaces(identifier, worker_host)

  @spec run_before_run_hook(Path.t(), issue_ref()) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue), do: Hooks.run_before_run_hook(workspace, issue, nil)

  @spec run_before_run_hook(Path.t(), issue_ref(), worker_host()) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue, worker_host),
    do: Hooks.run_before_run_hook(workspace, issue, worker_host)

  @spec run_after_run_hook(Path.t(), issue_ref()) :: :ok
  def run_after_run_hook(workspace, issue), do: Hooks.run_after_run_hook(workspace, issue, nil)

  @spec run_after_run_hook(Path.t(), issue_ref(), worker_host()) :: :ok
  def run_after_run_hook(workspace, issue, worker_host),
    do: Hooks.run_after_run_hook(workspace, issue, worker_host)

  @doc "Returns the collision-safe directory name for an issue identifier."
  @spec workspace_key(issue_ref()) :: String.t()
  def workspace_key(identifier), do: Paths.workspace_key(identifier)
end
