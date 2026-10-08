defmodule SymphonyElixir.Dispatch.DeliveryState.PersistenceBoundaryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Dispatch.DeliveryState.{Model, Store}
  alias SymphonyElixir.Dispatch.DeliveryState

  setup do
    dir = Path.join(System.tmp_dir!(), "delivery-persistence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "state.json")}
  end

  test "failed atomic rename preserves canonical bytes and removes only its temporary file", %{path: path} do
    prior = %{"version" => 1, "observed_at_ms" => 100, "entries" => [], "sources" => %{}}
    assert :ok = Store.save(path, prior)
    original = File.read!(path)
    marker = path <> ".interrupted.tmp"
    File.write!(marker, "incomplete prior attempt")
    parent = self()

    failure = fn temporary, destination ->
      assert destination == path
      assert {:ok, %{"observed_at_ms" => 110}} = temporary |> File.read!() |> Jason.decode()
      send(parent, {:rename_attempt, temporary})
      {:error, :enospc}
    end

    assert {:error, {:delivery_state, :persistence}} = Store.save(path, %{prior | "observed_at_ms" => 110}, failure)
    assert_received {:rename_attempt, temporary}
    refute File.exists?(temporary)
    assert File.read!(path) == original
    assert File.read!(marker) == "incomplete prior attempt"
    assert {:ok, %{observed_at_ms: 100}} = DeliveryState.read(path, 110, 20)
  end

  test "restart never adopts an orphan or silently resets malformed canonical state", %{path: path} do
    File.write!(path <> ".interrupted.tmp", Jason.encode!(%{"version" => 1, "observed_at_ms" => 100, "entries" => [], "sources" => %{}}))
    assert {:error, {:delivery_state, :missing}} = DeliveryState.read(path, 110, 20)

    malformed = [
      %{"version" => 2, "observed_at_ms" => 100, "entries" => [], "sources" => %{}},
      %{"version" => 1, "observed_at_ms" => 100, "entries" => [nil], "sources" => %{}},
      %{"version" => 1, "observed_at_ms" => 100, "entries" => [], "sources" => %{"issue-1" => 101}},
      %{"version" => 1, "observed_at_ms" => nil, "entries" => [], "sources" => %{}}
    ]

    for state <- malformed do
      File.write!(path, Jason.encode!(state))
      assert {:error, {:delivery_state, :corrupt}} = DeliveryState.read(path, 110, 20)
      assert {:error, {:delivery_state, :corrupt}} = Store.load_or_new(path)
    end
  end

  test "native terminal evidence must have valid timestamps no later than its revision" do
    pr = Path.expand("../../fixtures/dispatch_delivery/pull_request.json", __DIR__) |> File.read!() |> Jason.decode!()

    for invalid <- [
          Map.put(pr, "merged", true),
          Map.put(pr, "closed_at", "1970-01-01T00:00:00.080Z"),
          Map.merge(pr, %{"state" => "closed", "closed_at" => "1970-01-01T00:00:00.200Z"}),
          Map.merge(pr, %{"state" => "closed", "closed_at" => nil}),
          Map.merge(pr, %{"state" => "closed", "merged" => true, "merged_at" => "invalid"})
        ] do
      assert {:error, {:delivery_state, :incomplete_artifact}} = Model.decode_pr("owner/repo", "1", invalid)
    end
  end
end
