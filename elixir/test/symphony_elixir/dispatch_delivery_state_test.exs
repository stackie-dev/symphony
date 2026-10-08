defmodule SymphonyElixir.Dispatch.DeliveryStateTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Dispatch.DeliveryState

  setup do
    directory = Path.join(System.tmp_dir!(), "delivery-state-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, path: Path.join(directory, "state.json")}
  end

  test "public refresh deduplicates tracker references and durably reloads distinct artifacts", %{path: path} do
    options = options([pr(1), pr(2)])
    assert {:ok, snapshot} = DeliveryState.refresh(path, options)
    assert snapshot.complete
    assert snapshot.deliveries == [{"owner/repo", "1"}, {"owner/repo", "2"}]
    assert {:ok, ^snapshot} = DeliveryState.read(path, 110, 20)
  end

  test "new unfinished drafts do not count but review CI and protected merge waits do", %{path: path} do
    records = [pr(1, %{"draft" => true}), pr(2, %{"mergeable_state" => "blocked"})]
    assert {:ok, snapshot} = DeliveryState.refresh(path, options(records))
    assert snapshot.deliveries == [{"owner/repo", "2"}]
  end

  test "Done and missing links never remove known outstanding delivery", %{path: path} do
    assert {:ok, _} = DeliveryState.refresh(path, options([pr(1)]))
    next = options([pr(1, %{"updated_at" => "1970-01-01T00:00:00.120Z", "draft" => true})], links: false, now_ms: 130)
    assert {:ok, snapshot} = DeliveryState.refresh(path, next)
    assert snapshot.deliveries == [{"owner/repo", "1"}]
  end

  test "confirmed merge and native withdrawal remove; newer reopened revision counts again", %{path: path} do
    assert {:ok, _} = DeliveryState.refresh(path, options([pr(1), pr(2)]))
    merged = pr(1, %{"state" => "closed", "merged" => true, "merged_at" => "1970-01-01T00:00:00.120Z", "closed_at" => "1970-01-01T00:00:00.120Z", "updated_at" => "1970-01-01T00:00:00.120Z"})
    withdrawn = pr(2, %{"state" => "closed", "closed_at" => "1970-01-01T00:00:00.120Z", "updated_at" => "1970-01-01T00:00:00.120Z"})
    assert {:ok, %{deliveries: []}} = DeliveryState.refresh(path, options([merged, withdrawn], now_ms: 130))
    reopened = pr(2, %{"updated_at" => "1970-01-01T00:00:00.140Z", "head" => %{"sha" => "revised"}})
    assert {:ok, %{deliveries: [{"owner/repo", "2"}]}} = DeliveryState.refresh(path, options([merged, reopened], now_ms: 150))
  end

  test "stale conflicting future or incomplete evidence leaves durable bytes intact", %{path: path} do
    assert {:ok, _} = DeliveryState.refresh(path, options([pr(1)]))
    original = File.read!(path)

    variants = [
      options([pr(1, %{"updated_at" => "1970-01-01T00:00:00.080Z"})], now_ms: 130),
      options([pr(1, %{"head" => %{"sha" => "conflict"}})], now_ms: 130),
      options([pr(1, %{"updated_at" => "1970-01-01T00:00:00.200Z"})], now_ms: 130),
      Keyword.put(options([pr(1)], now_ms: 130), :pr_read, fn _, _ -> {:error, :timeout} end),
      Keyword.put(options([pr(1)], now_ms: 130), :tracker_read, fn _, _ -> {:error, :timeout} end)
    ]

    for opts <- variants do
      assert {:error, {:delivery_state, _}} = DeliveryState.refresh(path, opts)
      assert File.read!(path) == original
      assert {:ok, %{deliveries: [{"owner/repo", "1"}]}} = DeliveryState.read(path, 110, 20)
    end
  end

  test "missing corrupt stale future and failed persistence are explicit uncertainty", %{path: path} do
    assert {:error, {:delivery_state, :missing}} = DeliveryState.read(path, 110, 20)
    assert {:ok, _} = DeliveryState.refresh(path, options([pr(1)]))
    assert {:error, {:delivery_state, :stale}} = DeliveryState.read(path, 200, 20)
    assert {:error, {:delivery_state, :future}} = DeliveryState.read(path, 90, 20)
    File.write!(path, "{broken")
    assert {:error, {:delivery_state, :corrupt}} = DeliveryState.read(path, 110, 20)
    assert {:error, {:delivery_state, :corrupt}} = DeliveryState.refresh(path, options([pr(1)]))
    assert {:error, {:delivery_state, :persistence}} = DeliveryState.refresh(Path.join(path, "state"), options([pr(1)]))
  end

  defp options(records, overrides \\ []) do
    links? = Keyword.get(overrides, :links, true)
    urls = if links?, do: Enum.map_join(records, " ", &"https://github.com/OWNER/Repo/pull/#{&1["number"]}"), else: ""

    tracker = fn query, _variables ->
      field = if String.contains?(query, "attachments("), do: "attachments", else: "comments"
      nodes = if field == "comments", do: [%{"body" => urls <> " " <> urls}], else: []

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "id" => "issue-1",
             "updatedAt" => "1970-01-01T00:00:00.090Z",
             "description" => urls,
             "state" => %{"name" => "Done"},
             field => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
           }
         }
       }}
    end

    reader = fn "owner/repo", number ->
      case Enum.find(records, &(Integer.to_string(&1["number"]) == number)) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end

    Keyword.merge([issue_ids: ["issue-1", "issue-1"], repositories: ["owner/repo"], tracker_read: tracker, pr_read: reader, now_ms: 100, max_age_ms: 20], Keyword.delete(overrides, :links))
  end

  defp pr(number, overrides \\ %{}) do
    fixture = Path.expand("../fixtures/dispatch_delivery/pull_request.json", __DIR__)
    fixture |> File.read!() |> Jason.decode!() |> Map.put("number", number) |> Map.merge(overrides)
  end
end
