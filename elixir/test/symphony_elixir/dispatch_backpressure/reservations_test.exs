defmodule SymphonyElixir.Dispatch.Backpressure.ReservationsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Dispatch.{Admission, IntegrationOwner}

  setup do
    path = Path.join(System.tmp_dir!(), "admission-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path, now: System.system_time(:millisecond)}
  end

  defp snapshot(now, deliveries \\ []), do: %{version: 1, complete: true, observed_at_ms: now, deliveries: deliveries}
  defp writer(path, id, now, snapshot, resume \\ nil), do: Admission.reserve(path, id, :writer, "", resume, snapshot, now, 60_000)

  test "two durable writers, duplicate completion and verified retry never create a third slot", %{path: path, now: now} do
    assert {:ok, first} = writer(path, "one", now, snapshot(now))
    assert {:ok, _} = writer(path, "two", now, snapshot(now))
    assert {:error, :writer_capacity} = writer(path, "three", now, snapshot(now))
    assert {:error, :reservation_mismatch} = writer(path, "one", now, snapshot(now))
    assert {:ok, idle} = Admission.stopped(path, "one", first)
    assert {:ok, ^idle} = Admission.stopped(path, "one", first)
    assert {:ok, retry} = writer(path, "one", now, nil, idle)
    assert retry.token == first.token
    refute retry.session == first.session
    assert {:error, :reservation_mismatch} = Admission.stopped(path, "one", first)
    assert {:ok, %{writers: 2}} = Admission.status(path)
    assert {:error, :writer_capacity} = writer(path, "three", now, snapshot(now))
  end

  test "fresh complete backlog and regression block only new writers", %{path: path, now: now} do
    deliveries = [{"owner/repo", "1"}, {"owner/repo", "2"}, {"owner/repo", "2"}]
    assert {:error, :delivery_backpressure} = writer(path, "writer", now, snapshot(now, deliveries))
    assert {:ok, owner} = IntegrationOwner.acquire(path, "integration", "core")
    assert {:error, :integration_owned} = IntegrationOwner.acquire(path, "other", "core")
    assert {:ok, :held} = Admission.regression(path, %{id: "regression-1", scope: "core"})
    assert {:error, :integration_regression} = writer(path, "writer", now, snapshot(now))
    bad = %{regression_id: "regression-1", scope: "core", completed: false, exit_status: 0, tested_revision: "sha", receipt: "receipt"}
    assert {:error, :unproven_repair} = Admission.repaired(path, "integration", owner, bad)
    assert {:error, :unproven_repair} = Admission.repaired(path, "integration", owner, %{bad | completed: true, scope: "other"})
    assert {:error, :reservation_mismatch} = Admission.repaired(path, "integration", %{owner | token: "wrong"}, %{bad | completed: true})
    assert {:error, :unproven_repair} = Admission.repaired(path, "integration", owner, %{bad | completed: true, regression_id: "other"})
    assert {:ok, :repaired} = Admission.repaired(path, "integration", owner, %{bad | completed: true})
    assert {:ok, _} = writer(path, "writer", now, snapshot(now))
  end

  test "bounded repair shares exclusive owner and requires a matching durable regression", %{path: path, now: now} do
    assert {:error, :no_matching_regression_to_repair} = Admission.reserve(path, "repair", :repair, "core", nil, nil, now, 60_000)
    assert {:ok, :held} = Admission.regression(path, %{id: "r", scope: "core"})
    assert {:error, :no_matching_regression_to_repair} = Admission.reserve(path, "repair", :repair, "other", nil, nil, now, 60_000)
    assert {:ok, _} = Admission.reserve(path, "repair", :repair, "core", nil, nil, now, 60_000)
    assert {:error, :integration_owned} = Admission.reserve(path, "repair-two", :repair, "core", nil, nil, now, 60_000)
    assert {:error, :integration_owned} = IntegrationOwner.acquire(path, "integration", "core")
  end

  test "restart retains orphan owner and only exact token and stopped session proof recover it", %{path: path} do
    assert {:ok, handle} = IntegrationOwner.acquire(path, "integration", "core")
    assert {:error, :reservation_in_flight} = IntegrationOwner.acquire(path, "integration", "core", handle)
    assert {:error, :reservation_in_flight} = Admission.release(path, "integration", handle)
    proof = %{authority: :trusted_operator, stopped: true, session: handle.session, receipt: "verified remote session shutdown"}
    assert {:error, :unverified_stopped_session} = Admission.recover(path, "integration", handle, %{proof | session: "wrong"})
    assert {:error, :reservation_mismatch} = Admission.recover(path, "integration", %{handle | token: "wrong"}, proof)
    assert {:ok, idle} = Admission.recover(path, "integration", handle, proof)
    assert {:ok, retried} = IntegrationOwner.acquire(path, "integration", "core", idle)
    assert retried.token == handle.token
    assert {:ok, %{integration_owner: "integration", reservations: [record]}} = Admission.status(path)
    assert record.hold == :in_flight_or_recovery_required
    refute Map.has_key?(record, :token)
  end

  test "missing, corrupt, locked and stale observations never mean empty capacity", %{path: path, now: now} do
    assert {:error, :incomplete_delivery_state} = writer(path, "one", now, nil)
    assert {:error, :stale_capacity} = writer(path, "one", now, snapshot(now - 60_001))
    assert {:error, :future_capacity} = writer(path, "one", now, snapshot(now + 1))
    assert {:error, _} = writer(path, "one", now, %{snapshot(now) | deliveries: [nil]})
    File.mkdir!(Path.join(path, "lock"))
    assert {:error, :journal_busy} = IntegrationOwner.acquire(path, "integration", "core")
    File.rmdir!(Path.join(path, "lock"))
    File.write!(Path.join(path, "admission.term"), "corrupt")
    assert {:error, :corrupt_journal} = IntegrationOwner.acquire(path, "integration", "core")
    File.rm!(Path.join(path, "admission.term"))
    assert {:error, :missing_journal} = IntegrationOwner.acquire(path, "integration", "core")
  end
end
