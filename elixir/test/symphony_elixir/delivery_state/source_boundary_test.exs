defmodule SymphonyElixir.Dispatch.DeliveryState.SourceBoundaryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Dispatch.DeliveryState

  setup do
    dir = Path.join(System.tmp_dir!(), "delivery-source-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "state.json")}
  end

  test "real GitHub read adapter uses only GET for selected canonical links", %{path: path} do
    parent = self()

    request = fn method, route, params, body, _settings ->
      send(parent, {:http, method, route, params, body})
      {:ok, %{status: 200, body: pr()}}
    end

    tracker = fn query, vars ->
      send(parent, {:graphql, query, vars})
      field = field(query)

      nodes =
        if field == "attachments",
          do: [%{"url" => "https://github.com/OWNER/REPO/pull/1"}],
          else: [%{"body" => "retry https://github.com/owner/repo/pull/1 unrelated https://github.com/other/repo/pull/9"}]

      {:ok, page(field, nodes, false, nil)}
    end

    github = [tracker_settings: %{provider: %{"repo" => "owner/repo", "token" => "redacted-fixture-only"}}, request_fun: request]
    assert {:ok, %{deliveries: [{"owner/repo", "1"}]}} = DeliveryState.refresh(path, opts(tracker) ++ [github_options: github])
    assert_received {:http, "GET", "/repos/owner/repo/pulls/1", %{}, nil}
    refute_received {:http, _, _, _, _}
    assert_received {:graphql, query, %{id: "issue-1", after: nil}}
    refute String.contains?(query, "mutation")
  end

  test "complete comment pagination counts independent artifacts once", %{path: path} do
    parent = self()

    tracker = fn query, vars ->
      send(parent, {:page, field(query), vars.after})

      case {field(query), vars.after} do
        {"attachments", nil} -> {:ok, page("attachments", [], false, nil)}
        {"comments", nil} -> {:ok, page("comments", [%{"body" => "https://github.com/owner/repo/pull/1"}], true, "next")}
        {"comments", "next"} -> {:ok, page("comments", [%{"body" => "duplicate https://github.com/owner/repo/pull/1"}], false, nil)}
      end
    end

    assert {:ok, %{deliveries: [{"owner/repo", "1"}]}} = DeliveryState.refresh(path, opts(tracker) ++ [pr_read: fn _, _ -> {:ok, pr()} end])
    assert_received {:page, "comments", "next"}
  end

  test "partial cyclic malformed or changing tracker pages retain prior durable backlog", %{path: path} do
    good = fn query, _ -> {:ok, page(field(query), [], false, nil)} end
    known = fn query, _ -> {:ok, page(field(query), [], false, nil, "https://github.com/owner/repo/pull/1")} end
    reader = fn _, _ -> {:ok, pr()} end
    assert {:ok, _} = DeliveryState.refresh(path, opts(known) ++ [pr_read: reader])
    before = File.read!(path)

    bad = [
      fn _, _ -> {:error, :timeout} end,
      fn query, _ -> {:ok, page(field(query), [], true, nil)} end,
      fn query, _ -> {:ok, page(field(query), [], true, "loop")} end,
      fn query, _ -> {:ok, page(field(query), [%{"url" => nil, "body" => nil}], false, nil)} end,
      fn _, _ -> {:ok, %{"errors" => [%{"message" => "redacted"}]}} end,
      fn query, vars ->
        if vars.after == nil,
          do: {:ok, page(field(query), [], true, "next")},
          else: {:ok, put_in(page(field(query), [], false, nil), ["data", "issue", "updatedAt"], "1970-01-01T00:00:00.095Z")}
      end
    ]

    for tracker <- bad do
      assert {:error, {:delivery_state, :incomplete_tracker}} = DeliveryState.refresh(path, opts(tracker) ++ [pr_read: reader])
      assert File.read!(path) == before
    end

    # An empty later selected-issue discovery still queries the known PR.
    assert {:ok, %{deliveries: [{"owner/repo", "1"}]}} = DeliveryState.refresh(path, opts(good) ++ [pr_read: reader])
  end

  test "malformed missing or mismatched artifact identity cannot clear durable state", %{path: path} do
    tracker = fn query, _ -> {:ok, page(field(query), [], false, nil, "https://github.com/owner/repo/pull/1")} end
    assert {:ok, _} = DeliveryState.refresh(path, opts(tracker) ++ [pr_read: fn _, _ -> {:ok, pr()} end])
    before = File.read!(path)

    for response <- [{:error, :not_found}, {:ok, nil}, {:ok, Map.put(pr(), "draft", nil)}, {:ok, Map.put(pr(), "number", 2)}, {:ok, Map.put(pr(), "merged", nil)}] do
      assert {:error, {:delivery_state, :incomplete_artifact}} = DeliveryState.refresh(path, opts(tracker) ++ [pr_read: fn _, _ -> response end])
      assert File.read!(path) == before
    end
  end

  test "same native PR number in separately linked repositories remains distinct", %{path: path} do
    tracker = fn query, _ ->
      {:ok, page(field(query), [], false, nil, "https://github.com/owner/repo/pull/1 https://github.com/other/repo/pull/1")}
    end

    reader = fn repo, "1" -> {:ok, put_in(pr(), ["base", "repo", "full_name"], repo)} end
    options = opts(tracker) |> Keyword.put(:repositories, ["owner/repo", "other/repo"]) |> Keyword.put(:pr_read, reader)
    assert {:ok, %{deliveries: [{"other/repo", "1"}, {"owner/repo", "1"}]}} = DeliveryState.refresh(path, options)
  end

  test "out of order tracker revisions cannot replace the durable complete observation", %{path: path} do
    tracker = fn query, _ -> {:ok, page(field(query), [], false, nil, "https://github.com/owner/repo/pull/1")} end
    assert {:ok, _} = DeliveryState.refresh(path, opts(tracker) ++ [pr_read: fn _, _ -> {:ok, pr()} end])
    before = File.read!(path)
    stale = fn query, _ -> {:ok, put_in(page(field(query), [], false, nil), ["data", "issue", "updatedAt"], "1970-01-01T00:00:00.080Z")} end
    assert {:error, {:delivery_state, :stale_source}} = DeliveryState.refresh(path, opts(stale) ++ [pr_read: fn _, _ -> {:ok, pr()} end])
    assert File.read!(path) == before
  end

  test "invalid or narrowed repository authority never reads outside its allowlist", %{path: path} do
    tracker = fn query, _ -> {:ok, page(field(query), [], false, nil, "https://github.com/owner/repo/pull/1")} end
    assert {:ok, _} = DeliveryState.refresh(path, opts(tracker) ++ [pr_read: fn _, _ -> {:ok, pr()} end])
    before = File.read!(path)
    parent = self()

    reader = fn repo, number ->
      send(parent, {:unexpected_read, repo, number})
      {:ok, pr()}
    end

    narrowed = opts(tracker) |> Keyword.put(:repositories, ["other/repo"]) |> Keyword.put(:pr_read, reader)
    assert {:error, {:delivery_state, :incomplete_artifact}} = DeliveryState.refresh(path, narrowed)
    refute_received {:unexpected_read, _, _}
    assert File.read!(path) == before

    for repos <- [nil, ["../.."], ["owner/.."], ["owner/repo/extra"], [nil]] do
      assert {:error, {:delivery_state, :invalid_options}} = DeliveryState.refresh(path, Keyword.put(narrowed, :repositories, repos))
    end
  end

  defp opts(tracker), do: [issue_ids: ["issue-1"], repositories: ["owner/repo"], tracker_read: tracker, now_ms: 100, max_age_ms: 20]
  defp field(query), do: if(String.contains?(query, "attachments("), do: "attachments", else: "comments")

  defp page(field, nodes, next?, cursor, description \\ "") do
    %{
      "data" => %{
        "issue" => %{
          "id" => "issue-1",
          "updatedAt" => "1970-01-01T00:00:00.090Z",
          "description" => description,
          field => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next?, "endCursor" => cursor}}
        }
      }
    }
  end

  defp pr do
    Path.expand("../../fixtures/dispatch_delivery/pull_request.json", __DIR__) |> File.read!() |> Jason.decode!()
  end
end
