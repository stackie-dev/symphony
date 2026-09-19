defmodule SymphonyElixir.Dispatch.Eligibility do
  @moduledoc """
  Pure Linear leaf policy shared by initial attempts and explicit resumption.
  `:ok` is eligibility only; placement, freshness, capacity and fencing must still
  pass before launch. No tracker, filesystem, process or model calls occur here.
  """
  alias SymphonyElixir.Dispatch.{Snapshot, Validation}
  @type policy :: %{repositories: [String.t()], route: String.t()}
  @type reason ::
          :invalid_policy
          | :incomplete_metadata
          | :invalid_metadata
          | :inactive
          | :aggregate
          | :escalated
          | :prerequisites
          | :repository
          | :route
          | :assignment

  @spec check(term(), term()) :: :ok | {:reject, [reason()]}
  def check(snapshot, policy) do
    if valid_policy?(policy) do
      case Validation.snapshot(snapshot) do
        :ok -> decide(snapshot, policy)
        {:error, {:incomplete, :snapshot}} -> {:reject, [:incomplete_metadata]}
        {:error, {:invalid, :snapshot}} -> {:reject, [:invalid_metadata]}
      end
    else
      {:reject, [:invalid_policy]}
    end
  end

  defp decide(%Snapshot{issue: issue} = snapshot, policy) do
    checks = [
      inactive: issue.state not in ["Todo", "In Progress"],
      aggregate: snapshot.child_ids != [],
      escalated: Enum.any?(issue.labels, &(&1 in ["blocked", "needs-stronger-review", "release-waiting"])),
      prerequisites: Enum.any?(issue.blocked_by, &(&1.state != "Done")),
      repository: not repository_matches?(snapshot, policy.repositories),
      route: not route_matches?(snapshot, policy.route),
      assignment: is_nil(snapshot.project_id) or is_nil(issue.assignee_id)
    ]

    case for {reason, true} <- checks, do: reason do
      [] -> :ok
      reasons -> {:reject, reasons}
    end
  end

  defp repository_matches?(snapshot, repositories) do
    labels = Enum.filter(snapshot.issue.labels, &String.starts_with?(&1, "repo:"))
    snapshot.repository in repositories and labels == ["repo:" <> snapshot.repository]
  end

  defp route_matches?(snapshot, route) do
    labels = Enum.filter(snapshot.issue.labels, &(&1 == "symphony" or String.starts_with?(&1, "symphony-")))
    snapshot.route == route and labels == [route]
  end

  defp valid_policy?(%{repositories: repositories, route: route}) when is_list(repositories) and is_binary(route) do
    repositories != [] and Enum.all?(repositories, &valid_repository?/1) and
      Regex.match?(~r/^symphony(?:-[a-z0-9-]+)?$/, route)
  end

  defp valid_policy?(_), do: false
  defp valid_repository?(value), do: is_binary(value) and String.trim(value) != ""
end
