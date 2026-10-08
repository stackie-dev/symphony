defmodule SymphonyElixir.Dispatch.IntegrationOwner do
  @moduledoc "Exclusive durable integration duty, sharing the admission journal with bounded repair reservations."
  alias SymphonyElixir.Dispatch.Admission

  @spec acquire(Path.t(), String.t(), String.t(), map() | nil) :: tuple()
  def acquire(path, issue_id, scope, resume \\ nil) do
    Admission.reserve(path, issue_id, :integration, scope, resume, nil, System.system_time(:millisecond), 60_000)
  end

  @spec release(Path.t(), String.t(), map()) :: tuple()
  defdelegate release(path, issue_id, handle), to: Admission
end
