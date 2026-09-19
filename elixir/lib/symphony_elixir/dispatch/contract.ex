defmodule SymphonyElixir.Dispatch.Contract do
  @moduledoc """
  Version-one structural boundary for dispatch observations. `validate/3` grants
  no permission: eligibility, freshness, placement, capacity and exclusive
  ownership must still pass at the orchestrator's final launch boundary.
  """
  alias SymphonyElixir.Dispatch.{Attempt, Snapshot, Validation, Worker}
  @type error :: {:error, {:incomplete | :invalid, :snapshot | :worker | :attempt}}
  @type context :: %{snapshot: Snapshot.t(), worker: Worker.t(), attempt: Attempt.t()}

  @spec validate(term(), term(), term()) :: {:ok, context()} | error()
  def validate(snapshot, worker, attempt) do
    with :ok <- Validation.snapshot(snapshot),
         :ok <- Validation.worker(worker),
         :ok <- Validation.attempt(attempt) do
      {:ok, %{snapshot: snapshot, worker: worker, attempt: attempt}}
    end
  end

  @doc "Canonical identity for a structurally validated snapshot; route and host are excluded."
  @spec identity(Snapshot.t()) :: {String.t(), String.t(), String.t()}
  def identity(%Snapshot{scope: {tracker, organisation}, canonical_issue_id: id}), do: {tracker, organisation, id}
end
