defmodule SymphonyElixir.DispatchIntegrationBackpressureTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Dispatch.{Admission, IntegrationOwner}
  alias SymphonyElixir.Dispatch.Admission.Launch

  defp config do
    base = Workflow.workflow_file_path() |> Path.dirname()

    {:ok, config} =
      Launch.config(
        %{"repositories" => ["fixture/repository"], "issue_ids" => [], "integration_scopes" => %{"integration" => "core"}, "repair_scopes" => %{"repair" => "core"}},
        base
      )

    Map.put(config, :reader_options, Application.fetch_env!(:symphony_elixir, :dispatch_reader_options))
  end

  test "actual canonical reader composes with reservations and retry never double-counts" do
    config = config()
    assert {:ok, first} = Launch.acquire({:ok, config}, "one", nil)
    assert {:ok, _} = Launch.acquire({:ok, config}, "two", nil)
    assert {:error, :writer_capacity} = Launch.acquire({:ok, config}, "three", nil)
    assert {:ok, idle} = Launch.stopped({:ok, config}, "one", first)
    assert {:ok, retry} = Launch.acquire({:ok, config}, "one", idle)
    assert retry.token == first.token
    assert {:ok, %{writers: 2}} = Launch.status({:ok, config})
    assert {:ok, _} = Launch.acquire({:ok, config}, "integration", nil)
  end

  test "actual and remembered issue IDs remain selected after release and restart" do
    parent = self()

    config =
      Map.put(config(), :refresh, fn _, opts ->
        send(parent, {:selected, opts[:issue_ids]})
        {:ok, %{version: 1, complete: true, observed_at_ms: System.system_time(:millisecond), deliveries: []}}
      end)

    assert {:ok, handle} = Launch.acquire({:ok, config}, "completed-issue", nil)
    assert_receive {:selected, ["completed-issue"]}
    assert {:ok, idle} = Launch.stopped({:ok, config}, "completed-issue", handle)
    assert {:ok, :released} = Launch.release({:ok, config}, "completed-issue", idle)
    assert {:ok, _} = Launch.acquire({:ok, config}, "next-issue", nil)
    assert_receive {:selected, ids}
    assert Enum.sort(ids) == ["completed-issue", "next-issue"]
  end

  test "refresh failure never falls back to last good persisted reader; integration still progresses" do
    config = config()
    assert {:ok, _} = Launch.acquire({:ok, config}, "one", nil)
    failing = Map.put(config, :refresh, fn _, _ -> {:error, {:delivery_state, :unavailable}} end)
    assert {:error, {:delivery_state, :unavailable}} = Launch.acquire({:ok, failing}, "two", nil)
    assert {:ok, %{writers: 1}} = Launch.status({:ok, config})
    assert {:ok, _} = Launch.acquire({:ok, failing}, "integration", nil)
    assert {:error, :integration_owned} = IntegrationOwner.acquire(config.path, "other", "core")
  end

  test "trusted workflow roles cannot overlap and unconfigured dispatch fails closed" do
    assert {:error, :missing_dispatch_config} = Launch.config(nil, "/tmp")
    assert {:error, :missing_dispatch_config} = Launch.acquire({:error, :missing_dispatch_config}, "one", nil)

    assert {:error, :invalid_dispatch_config} =
             Launch.config(
               %{"repositories" => ["fixture/repo"], "issue_ids" => [], "integration_scopes" => %{"one" => "core"}, "repair_scopes" => %{"one" => "core"}},
               "/tmp"
             )

    config = config()
    assert {:error, :no_matching_regression_to_repair} = Launch.acquire({:ok, config}, "repair", nil)
    assert {:ok, :held} = Admission.regression(config.path, %{id: "regression", scope: "core"})
    assert {:ok, _} = Launch.acquire({:ok, config}, "repair", nil)
    assert {:error, :integration_owned} = Launch.acquire({:ok, config}, "integration", nil)
  end

  test "real orchestrator failed spawn retains one idle retry reservation and recovery/status are wired" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    config = config()
    path = Workflow.workflow_file_path()
    text = File.read!(path)
    File.write!(path, String.replace(text, "  issue_ids: []\n", "  issue_ids: []\n  integration_scopes: {integration: core}\n"))
    :ok = WorkflowStore.force_reload()
    issue = %Issue{id: "one", identifier: "STA-201", title: "Admission boundary", state: "Todo", url: "https://example.test/one"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    supervisor = start_supervised!({Task.Supervisor, max_children: 0})
    server = start_supervised!({Orchestrator, name: nil, task_supervisor: supervisor})
    send(server, :run_poll_cycle)
    status = GenServer.call(server, :snapshot)
    assert status.running == []
    state = :sys.get_state(server)
    assert %{status: :idle} = first = state.dispatch_reservations["one"]
    assert {:ok, %{writers: 1}} = Admission.status(config.path)
    retry = state.retry_attempts["one"]
    send(server, {:retry_issue, "one", retry.retry_token})
    _ = GenServer.call(server, :snapshot)
    next = :sys.get_state(server)
    assert next.dispatch_reservations["one"].token == first.token
    assert {:ok, %{writers: 1}} = Admission.status(config.path)
    assert {:ok, owner} = IntegrationOwner.acquire(config.path, "integration", "core")
    proof = %{authority: :trusted_operator, stopped: true, session: owner.session, receipt: "verified stopped"}
    assert {:error, :reservation_mismatch} = Orchestrator.recover_dispatch(server, "integration", %{owner | token: "wrong"}, proof)
    assert {:ok, :recovered} = Orchestrator.recover_dispatch(server, "integration", owner, proof)
    assert :sys.get_state(server).dispatch_reservations["integration"].token == owner.token
    assert %{dispatch: %{authority: {:ok, %{integration_owner: "integration"}}}} = GenServer.call(server, :snapshot)
  end
end
