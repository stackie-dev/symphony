defmodule SymphonyElixir.Workspace.Context do
  @moduledoc """
  Builds stable issue and worker context for workspace lifecycle logs.

  Missing tracker fields are normalized here so callers do not invent per-hook fallbacks.
  """

  @type issue_context :: %{issue_id: term(), issue_identifier: String.t()}

  @spec issue_context(map() | String.t() | nil) :: issue_context()
  def issue_context(%{id: issue_id, identifier: identifier}) do
    %{issue_id: issue_id, issue_identifier: identifier || "issue"}
  end

  def issue_context(identifier) when is_binary(identifier) do
    %{issue_id: nil, issue_identifier: identifier}
  end

  def issue_context(_identifier), do: %{issue_id: nil, issue_identifier: "issue"}

  @spec issue_log_context(issue_context()) :: String.t()
  def issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  @spec worker_host_for_log(String.t() | nil) :: String.t()
  def worker_host_for_log(nil), do: "local"
  def worker_host_for_log(worker_host), do: worker_host
end
