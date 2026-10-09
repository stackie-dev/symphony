defmodule SymphonyElixir.Dispatch.Backpressure.ProcessContentionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Dispatch.{Admission, IntegrationOwner}

  test "independent operating-system processes contend for one durable owner and retain it after exit" do
    path = Path.join(System.tmp_dir!(), "admission-processes-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:ok, _} = Admission.status(path)
    elixir = System.find_executable("elixir") || flunk("Elixir executable required for cross-process proof")
    code_paths = :code.get_path() |> Enum.flat_map(fn p -> ["-pa", List.to_string(p)] end)

    tasks =
      for id <- ["first", "second"] do
        Task.async(fn ->
          script = "result = SymphonyElixir.Dispatch.IntegrationOwner.acquire(System.fetch_env!(\"CLAIM_PATH\"), System.fetch_env!(\"CLAIM_ID\"), \"core\"); IO.puts(inspect({System.pid(), result}))"
          System.cmd(elixir, code_paths ++ ["-e", script], env: [{"CLAIM_PATH", path}, {"CLAIM_ID", id}], stderr_to_stdout: true)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 30_000))
    assert Enum.all?(results, fn {_, exit} -> exit == 0 end), inspect(results)
    outputs = Enum.map(results, &elem(&1, 0))
    assert Enum.count(outputs, &String.contains?(&1, "{:ok,")) == 1, inspect(outputs)
    assert Enum.count(outputs, &(String.contains?(&1, ":integration_owned") or String.contains?(&1, ":journal_busy"))) == 1
    pids = Enum.map(outputs, fn out -> Regex.run(~r/\{"(\d+)"/, out, capture: :all_but_first) end)
    assert Enum.all?(pids, &match?([_], &1)), inspect(outputs)
    assert length(Enum.uniq(pids)) == 2
    assert {:error, :integration_owned} = IntegrationOwner.acquire(path, "after-restart", "core")
    assert {:ok, %{integration_owner: owner}} = Admission.status(path)
    assert owner in ["first", "second"]
  end
end
