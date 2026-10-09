defmodule SymphonyElixir.Dispatch.Admission do
  @moduledoc "Durable admission API. Handles are private capabilities; only observed shutdown or trusted stopped-session proof permits reuse."
  alias SymphonyElixir.Dispatch.Admission.Reservations

  @spec reserve(Path.t(), String.t(), atom(), String.t(), map() | nil, map() | nil, integer(), integer()) :: tuple()
  defdelegate reserve(path, id, role, scope, resume, snapshot, now, age), to: Reservations

  @spec selection(Path.t(), String.t()) :: tuple()
  defdelegate selection(path, id), to: Reservations

  @spec stopped(Path.t(), String.t(), map()) :: tuple()
  defdelegate stopped(path, id, handle), to: Reservations

  @spec recover(Path.t(), String.t(), map(), map()) :: tuple()
  defdelegate recover(path, id, handle, proof), to: Reservations

  @spec release(Path.t(), String.t(), map()) :: tuple()
  defdelegate release(path, id, handle), to: Reservations

  @spec regression(Path.t(), map()) :: tuple()
  defdelegate regression(path, regression), to: Reservations

  @spec repaired(Path.t(), String.t(), map(), map()) :: tuple()
  defdelegate repaired(path, id, handle, proof), to: Reservations

  @spec status(Path.t()) :: tuple()
  defdelegate status(path), to: Reservations
end
