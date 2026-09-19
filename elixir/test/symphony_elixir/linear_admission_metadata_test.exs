defmodule SymphonyElixir.Linear.AdmissionMetadataTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.AdmissionConnection
  alias SymphonyElixir.Linear.AdmissionMetadata
  alias SymphonyElixir.Tracker.Issue

  test "all labels, children and incoming blockers are collected before completeness" do
    reader = fn query, vars ->
      cond do
        String.contains?(query, "inverseRelations(") ->
          next? = is_nil(vars.after)

          blockers =
            if next?,
              do: [%{"type" => "related", "issue" => nil}],
              else: [%{"type" => "blocks", "issue" => %{"id" => "b", "state" => %{"name" => "Todo"}}}]

          page("inverseRelations", blockers, next?, "next")

        String.contains?(query, "children(") ->
          if is_nil(vars.after),
            do: page("children", [], true, "children-next"),
            else: page("children", [%{"id" => "child"}], false, nil)

        String.contains?(query, "labels(") ->
          page("labels", [%{"name" => "repo:parent"}], false, nil)

        true ->
          metadata()
      end
    end

    original = %Issue{id: "native", description: "existing GitHub source information", branch_name: "existing"}
    assert {:ok, snapshot} = AdmissionMetadata.fetch(original, "org", "symphony-canary", reader)
    assert snapshot.complete
    assert snapshot.child_ids == ["child"]
    assert snapshot.issue.blocked_by == [%{id: "b", state: "Todo"}]
    assert snapshot.issue.description == original.description
    assert snapshot.issue.branch_name == original.branch_name
    assert snapshot.canonical_issue_id == "native"
    assert snapshot.project_id == "project"
  end

  test "truncated pages, repeated cursors and partial GraphQL errors fail closed" do
    for malformed <- [
          {:ok, %{"data" => %{"issue" => %{"labels" => %{"nodes" => []}}}}},
          page("labels", [], true, nil),
          {:ok, %{"data" => %{"issue" => %{}}, "errors" => [%{"message" => "private details"}]}},
          {:error, :offline}
        ] do
      reader = fn query, _ -> if String.contains?(query, "AdmissionIssue"), do: metadata(), else: malformed end
      assert {:error, _} = AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", reader)
    end

    reader = fn query, _ ->
      if String.contains?(query, "AdmissionIssue"), do: metadata(), else: page("labels", [], true, "same")
    end

    assert {:error, :pagination_cycle} = AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", reader)
  end

  test "missing blocker state and changed issue identity cannot look like no blockers" do
    reader = fn query, _ ->
      cond do
        String.contains?(query, "AdmissionIssue") -> metadata()
        String.contains?(query, "labels(") -> page("labels", [], false, nil)
        String.contains?(query, "children(") -> page("children", [], false, nil)
        true -> page("inverseRelations", [%{"type" => "blocks", "issue" => %{"id" => "b"}}], false, nil)
      end
    end

    assert {:error, :incomplete_blocker} =
             AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", reader)

    assert {:error, :issue_identity_changed} =
             AdmissionMetadata.fetch(%Issue{id: "different"}, "org", "symphony-canary", fn _, _ -> metadata() end)
  end

  test "connection traversal is bounded and validates every response shape" do
    reader = fn _, vars ->
      cursor = if vars.after, do: String.to_integer(vars.after) + 1, else: 1
      page("labels", [], true, Integer.to_string(cursor))
    end

    assert {:error, :pagination_limit} = AdmissionConnection.fetch("native", :labels, reader)

    for response <- [
          {:ok, %{}},
          {:ok, %{"errors" => ["private"]}},
          {:ok, %{"data" => %{"issue" => %{"id" => "native", "labels" => %{}}}}},
          {:error, {"secret", :offline}},
          :unexpected_callback_result
        ] do
      assert {:error, :incomplete_connection} =
               AdmissionConnection.fetch("native", :labels, fn _, _ -> response end)
    end
  end

  test "duplicate observations deduplicate but conflicting blocker states reject" do
    blocker = %{"type" => "blocks", "issue" => %{"id" => "b", "state" => %{"name" => "Done"}}}

    for {relations, expected} <- [
          {[blocker, blocker], :ok},
          {[blocker, put_in(blocker, ["issue", "state", "name"], "Todo")], :inconsistent_blocker},
          {[%{}], :incomplete_relation}
        ] do
      reader = fixture_reader([], [], relations)
      result = AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", reader)

      case expected do
        :ok -> assert {:ok, %{issue: %{blocked_by: [%{id: "b", state: "Done"}]}}} = result
        error -> assert {:error, ^error} = result
      end
    end
  end

  test "malformed nodes and core fields never become complete observations" do
    for labels <- [[%{}], [42], [[%{"name" => "nested"}]]] do
      assert {:error, :incomplete_nodes} =
               AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", fixture_reader(labels, [], []))
    end

    {:ok, good} = metadata()

    for body <- [%{}, Map.put(good, "errors", ["private"]), put_in(good, ["data", "issue", "assignee"], %{})] do
      assert {:error, _} =
               AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", fn _, _ -> {:ok, body} end)
    end

    assert {:error, :incomplete_metadata} =
             AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", fn _, _ ->
               {:error, {"private", :offline}}
             end)
  end

  test "observed null assignment is preserved and duplicate labels are deduplicated" do
    {:ok, good} = metadata()
    unassigned = good |> put_in(["data", "issue", "assignee"], nil) |> put_in(["data", "issue", "project"], nil)
    reader = fixture_reader([%{"name" => "repo:parent"}, %{"name" => "repo:parent"}], [], [], {:ok, unassigned})
    assert {:ok, snapshot} = AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", reader)
    assert snapshot.issue.labels == ["repo:parent"]
    assert is_nil(snapshot.issue.assignee_id)
    assert is_nil(snapshot.project_id)
  end

  test "freshness is measured from the oldest evidence before slow pagination" do
    Process.put(:observation_clock, 100)
    clock = fn -> Process.get(:observation_clock) end
    fixture = fixture_reader([], [], [])

    reader = fn query, variables ->
      Process.put(:observation_clock, clock.() + 1_000)
      fixture.(query, variables)
    end

    assert {:ok, snapshot} = AdmissionMetadata.fetch(%Issue{id: "native"}, "org", "symphony-canary", reader, clock)
    assert snapshot.observed_at_ms == 100
    assert clock.() == 4_100
  end

  defp fixture_reader(labels, children, relations, core \\ metadata()) do
    fn query, _ ->
      cond do
        String.contains?(query, "AdmissionIssue") -> core
        String.contains?(query, "labels(") -> page("labels", labels, false, nil)
        String.contains?(query, "children(") -> page("children", children, false, nil)
        true -> page("inverseRelations", relations, false, nil)
      end
    end
  end

  defp metadata do
    {:ok,
     %{
       "data" => %{
         "issue" => %{
           "id" => "native",
           "identifier" => "STA-1",
           "state" => %{"name" => "Todo"},
           "assignee" => %{"id" => "worker"},
           "project" => %{"id" => "project"}
         }
       }
     }}
  end

  defp page(field, nodes, next?, cursor) do
    {:ok,
     %{
       "data" => %{
         "issue" => %{
           "id" => "native",
           field => %{
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => next?, "endCursor" => cursor}
           }
         }
       }
     }}
  end
end
