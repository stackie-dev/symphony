defmodule SymphonyElixir.Dispatch.ContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Dispatch.{Attempt, Contract, Snapshot, Worker}
  alias SymphonyElixir.Tracker.Issue

  test "complete observations produce a validated context, never an admission decision" do
    {snapshot, worker, attempt} = observations()

    assert {:ok, %{snapshot: ^snapshot, worker: ^worker, attempt: ^attempt}} =
             Contract.validate(snapshot, worker, attempt)
  end

  test "missing evidence is distinct from contradictory or malformed evidence" do
    {snapshot, worker, attempt} = observations()

    for incomplete <- [%{snapshot | complete: false}, %{snapshot | child_ids: nil}] do
      assert {:error, {:incomplete, :snapshot}} = Contract.validate(incomplete, worker, attempt)
    end

    assert {:error, {:invalid, :snapshot}} = Contract.validate(%{snapshot | version: 2}, worker, attempt)
    assert {:error, {:invalid, :worker}} = Contract.validate(snapshot, %{worker | slots: -1}, attempt)
    assert {:error, {:incomplete, :attempt}} = Contract.validate(snapshot, worker, %{attempt | complete: false})
  end

  test "missing blocker states and malformed IDs cannot become empty evidence" do
    {snapshot, worker, attempt} = observations()
    missing = %{snapshot | issue: %{snapshot.issue | blocked_by: [%{id: "blocker", state: nil}]}}
    malformed = %{snapshot | child_ids: [42]}
    assert {:error, {:incomplete, :snapshot}} = Contract.validate(missing, worker, attempt)
    assert {:error, {:invalid, :snapshot}} = Contract.validate(malformed, worker, attempt)
    for state <- ["Done", "Todo"] do
      observed = %{snapshot | issue: %{snapshot.issue | blocked_by: [%{id: "blocker", state: state}]}}
      assert {:ok, _} = Contract.validate(observed, worker, attempt)
    end
  end

  test "structural validation does not decide eligibility, placement, age or backpressure" do
    {snapshot, worker, attempt} = observations()
    snapshot = %{snapshot | issue: %{snapshot.issue | state: "Backlog"}, observed_at_ms: 1}
    worker = %{worker | os: :unknown, available: false, slots: 0}
    attempt = %{attempt | active_writers: 2, deliveries: [{"repo", "pr-1"}, {"repo", "pr-2"}], regression: true}
    assert {:ok, _} = Contract.validate(snapshot, worker, attempt)
  end

  test "invalid observations fail closed without coercion" do
    {snapshot, worker, attempt} = observations()

    for invalid <- [%{snapshot | observed_at_ms: -1}, %{snapshot | route: ""}, %{snapshot | scope: {"linear", nil}}] do
      assert {:error, {:invalid, :snapshot}} = Contract.validate(invalid, worker, attempt)
    end

    assert {:error, {:invalid, :worker}} = Contract.validate(snapshot, %{worker | os: "linux"}, attempt)
    assert {:error, {:invalid, :attempt}} = Contract.validate(snapshot, worker, %{attempt | role: :arbitrary})
    assert {:error, {:invalid, :attempt}} = Contract.validate(snapshot, worker, %{attempt | deliveries: ["pr-1"]})
    assert {:error, {:incomplete, :snapshot}} = Contract.validate(nil, worker, attempt)
  end

  test "canonical issue identity excludes route and worker spelling" do
    {snapshot, _, _} = observations()
    assert {"linear", "org-1", "issue-1"} = Contract.identity(snapshot)
    assert Contract.identity(snapshot) == Contract.identity(%{snapshot | route: "symphony-other"})

    assert Contract.identity(snapshot) ==
             Contract.identity(%{snapshot | issue: %{snapshot.issue | id: "another-board-entry"}})

    refute Contract.identity(snapshot) == Contract.identity(%{snapshot | scope: {"linear", "org-2"}})
  end

  test "all observation boundaries reject absent or wrongly typed inputs" do
    {snapshot, worker, attempt} = observations()

    for {value, kind} <- [{nil, :incomplete}, {%{}, :invalid}] do
      assert {:error, {^kind, :worker}} = Contract.validate(snapshot, value, attempt)
      assert {:error, {^kind, :attempt}} = Contract.validate(snapshot, worker, value)
    end

    assert {:error, {:invalid, :snapshot}} = Contract.validate(%{}, worker, attempt)
    assert {:error, {:incomplete, :snapshot}} = Contract.validate(%{snapshot | issue: nil}, worker, attempt)

    for invalid <- [%{worker | version: 2}, %{worker | id: ""}, %{worker | available: :yes}] do
      assert {:error, {:invalid, :worker}} = Contract.validate(snapshot, invalid, attempt)
    end

    assert {:error, {:incomplete, :worker}} = Contract.validate(snapshot, %{worker | id: nil}, attempt)

    for invalid <- [
          %{attempt | version: 2},
          %{attempt | active_writers: -1},
          %{attempt | regression: :yes},
          %{attempt | preferred_host: ""}
        ] do
      assert {:error, {:invalid, :attempt}} = Contract.validate(snapshot, worker, invalid)
    end

    assert {:error, {:incomplete, :attempt}} = Contract.validate(snapshot, worker, %{attempt | deliveries: nil})
  end

  test "malformed tracker collections and flags are not accepted" do
    {snapshot, worker, attempt} = observations()

    for issue <- [
          %{snapshot.issue | blocked_by: :missing},
          %{snapshot.issue | blocked_by: [42]},
          %{snapshot.issue | labels: [42]},
          %{snapshot.issue | state: ""}
        ] do
      assert {:error, {:invalid, :snapshot}} = Contract.validate(%{snapshot | issue: issue}, worker, attempt)
    end

    assert {:error, {:invalid, :snapshot}} = Contract.validate(%{snapshot | complete: :yes}, worker, attempt)
    assert {:error, {:invalid, :snapshot}} = Contract.validate(%{snapshot | project_id: 42}, worker, attempt)

    assert {:ok, _} =
             Contract.validate(
               %{snapshot | project_id: "project-1", issue: %{snapshot.issue | assignee_id: "agent-1"}},
               worker,
               attempt
             )
  end

  defp observations do
    snapshot = %Snapshot{
      scope: {"linear", "org-1"},
      canonical_issue_id: "issue-1",
      issue: %Issue{id: "issue-1", identifier: "STA-1", state: "Todo", labels: [], blocked_by: []},
      child_ids: [],
      repository: "parent",
      route: "symphony-canary",
      complete: true,
      observed_at_ms: 100
    }

    worker = %Worker{id: "host-1", os: :linux, available: true, slots: 1, observed_at_ms: 100}

    attempt = %Attempt{
      role: :writer,
      active_writers: 0,
      deliveries: [],
      regression: false,
      complete: true,
      observed_at_ms: 100
    }

    {snapshot, worker, attempt}
  end
end
