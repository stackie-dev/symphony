defmodule SymphonyElixir.Workspace.Remote do
  @moduledoc """
  Runs bounded workspace commands on configured worker hosts.

  Remote timeout and SSH failures are returned to the lifecycle owner for fail-closed handling.
  """

  alias SymphonyElixir.SSH

  @spec run_command(String.t(), String.t(), pos_integer()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_command(worker_host, script, timeout_ms)
      when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fn -> SSH.run(worker_host, script, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end
end
