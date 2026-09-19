defmodule SymphonyElixir.Dispatch.EligibilityTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Dispatch.{Eligibility, Snapshot}
  alias SymphonyElixir.Tracker.Issue

  @policy %{repositories: ["parent", "stackie"], route: "symphony-canary"}

  test "native Linear leaf needs no GitHub source" do
    assert :ok = Eligibility.check(leaf(), @policy)
    assert :ok = Eligibility.check(%{leaf() | issue: %{leaf().issue | state: "In Progress"}}, @policy)
  end

  test "initial and resumed attempts require every prerequisite Done" do
    for state <- ["Todo", "In Progress"], prerequisite <- ["Todo", "In Review", "Canceled", "Duplicate"] do
      issue = %{leaf().issue | state: state, blocked_by: [%{id: "dependency", state: prerequisite}]}
      assert {:reject, [:prerequisites]} = Eligibility.check(%{leaf() | issue: issue}, @policy)
    end

    issue = %{leaf().issue | blocked_by: [%{id: "dependency", state: "Done"}]}
    assert :ok = Eligibility.check(%{leaf() | issue: issue}, @policy)
  end

  test "missing evidence is never an eligible empty collection" do
    assert {:reject, [:incomplete_metadata]} = Eligibility.check(%{leaf() | complete: false}, @policy)
    assert {:reject, [:incomplete_metadata]} = Eligibility.check(%{leaf() | child_ids: nil}, @policy)
    assert {:reject, [:invalid_metadata]} = Eligibility.check(%{leaf() | version: 2}, @policy)
  end

  test "aggregates, inactive work, escalation and assignment are independent reasons" do
    for label <- ["blocked", "needs-stronger-review", "release-waiting"] do
      issue = %{leaf().issue | labels: leaf().issue.labels ++ [label]}
      assert {:reject, [:escalated]} = Eligibility.check(%{leaf() | issue: issue}, @policy)
    end

    assert {:reject, [:aggregate]} = Eligibility.check(%{leaf() | child_ids: ["child"]}, @policy)
    assert {:reject, [:assignment]} = Eligibility.check(%{leaf() | project_id: nil}, @policy)
    issue = %{leaf().issue | state: "Backlog", assignee_id: nil}
    assert {:reject, [:inactive, :assignment]} = Eligibility.check(%{leaf() | issue: issue}, @policy)
  end

  test "one known repository and exactly the intended route must agree with evidence" do
    for labels <- [["repo:other"], ["repo:parent", "repo:stackie"], []] do
      issue = %{leaf().issue | labels: labels ++ ["symphony-canary"]}
      assert {:reject, [:repository]} = Eligibility.check(%{leaf() | issue: issue}, @policy)
    end

    for routes <- [[], ["symphony"], ["symphony-canary", "symphony"], ["symphony-other"]] do
      issue = %{leaf().issue | labels: ["repo:parent"] ++ routes}
      assert {:reject, [:route]} = Eligibility.check(%{leaf() | issue: issue}, @policy)
    end

    assert {:reject, [:repository]} = Eligibility.check(%{leaf() | repository: "stackie"}, @policy)
    assert {:reject, [:route]} = Eligibility.check(%{leaf() | route: "symphony-other"}, @policy)
  end

  test "invalid policy fails closed without exceptions and multiple reasons are stable" do
    for policy <- [nil, %{}, %{repositories: [], route: "symphony-canary"}] do
      assert {:reject, [:invalid_policy]} = Eligibility.check(leaf(), policy)
    end

    issue = %{leaf().issue | state: "Backlog", labels: ["blocked"], blocked_by: [%{id: "x", state: "Todo"}]}
    value = %{leaf() | issue: issue, child_ids: ["child"], project_id: nil}
    expected = [:inactive, :aggregate, :escalated, :prerequisites, :repository, :route, :assignment]
    assert {:reject, ^expected} = Eligibility.check(value, @policy)
  end

  defp leaf do
    %Snapshot{
      scope: {"linear", "org"},
      canonical_issue_id: "ticket",
      project_id: "project",
      issue: %Issue{id: "ticket", state: "Todo", assignee_id: "worker", labels: ["repo:parent", "symphony-canary"]},
      child_ids: [],
      repository: "parent",
      route: "symphony-canary",
      observed_at_ms: 100,
      complete: true
    }
  end

  test "versioned preflight fixtures agree with the runtime eligibility decision" do
    path = Path.expand("../fixtures/dispatch_admission_v1.json", __DIR__)
    fixture = path |> File.read!() |> JSON.decode!()
    assert fixture["version"] == 1
    policy = %{repositories: fixture["policy"]["repositories"], route: fixture["policy"]["routeLabel"]}

    for scenario <- fixture["cases"] do
      data = Map.merge(fixture["base"], scenario["patch"])

      issue = %Issue{
        id: "ticket",
        state: data["state"],
        labels: data["labels"],
        assignee_id: data["assigneeId"],
        blocked_by: Enum.map(data["blockers"], &%{id: &1["id"], state: &1["state"]})
      }

      repository_label = Enum.find(data["labels"], "repo:missing", &String.starts_with?(&1, "repo:"))

      snapshot = %{
        leaf()
        | issue: issue,
          child_ids: data["children"],
          project_id: data["projectId"],
          repository: String.replace_prefix(repository_label, "repo:", ""),
          route: policy.route
      }

      eligible? = Eligibility.check(snapshot, policy) == :ok
      assert eligible? == scenario["ready"], scenario["name"]
    end
  end
end
