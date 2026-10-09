defmodule SymphonyElixir.Dispatch.Admission.Reservations do
  @moduledoc "Atomic two-writer reservations and one integration/repair owner; idle retries retain their original slot."
  alias SymphonyElixir.Dispatch.{Attempt, Capacity}
  alias SymphonyElixir.Dispatch.Admission.Store

  @spec reserve(Path.t(), String.t(), atom(), String.t(), map() | nil, map() | nil, integer(), integer()) :: tuple()
  def reserve(path, id, role, scope, resume, snapshot, now, age)
      when is_binary(id) and byte_size(id) > 0 and role in [:writer, :integration, :repair] and is_binary(scope) do
    Store.transact(path, fn state ->
      case Map.get(state.reservations, id) do
        nil -> create(state, id, role, scope, resume, snapshot, now, age)
        record -> resume(state, id, record, role, scope, resume)
      end
    end)
  end

  def reserve(_, _, _, _, _, _, _, _), do: {:error, :invalid_reservation}

  @spec selection(Path.t(), String.t()) :: tuple()
  def selection(path, id) when is_binary(id) and byte_size(id) > 0 do
    Store.transact(path, fn state ->
      ids = Enum.uniq([id | state.selected_issue_ids] ++ Map.keys(state.reservations))
      {:ok, ids, %{state | selected_issue_ids: ids}}
    end)
  end

  @spec stopped(Path.t(), String.t(), map()) :: tuple()
  def stopped(path, id, handle) do
    update(path, id, handle, fn state, record ->
      next = %{record | status: :idle}
      {:ok, next, put_in(state, [:reservations, id], next)}
    end)
  end

  @spec recover(Path.t(), String.t(), map(), map()) :: tuple()
  def recover(path, id, handle, proof) do
    if is_map(handle) and is_map(proof) and proof[:stopped] == true and proof[:session] == handle[:session] and
         proof[:authority] == :trusted_operator and is_binary(proof[:receipt]) and proof[:receipt] != "" do
      stopped(path, id, handle)
    else
      {:error, :unverified_stopped_session}
    end
  end

  @spec release(Path.t(), String.t(), map()) :: tuple()
  def release(path, id, handle) do
    update(path, id, handle, fn state, record ->
      if record.status == :idle do
        next = %{state | reservations: Map.delete(state.reservations, id)}
        next = if next.owner == id, do: %{next | owner: nil}, else: next
        {:ok, :released, next}
      else
        {:error, :reservation_in_flight}
      end
    end)
  end

  @spec regression(Path.t(), map()) :: tuple()
  def regression(path, %{id: id, scope: scope} = regression)
      when is_binary(id) and byte_size(id) > 0 and is_binary(scope) and byte_size(scope) > 0 do
    Store.transact(path, fn state ->
      {:ok, :held, %{state | regression: Map.take(regression, [:id, :scope])}}
    end)
  end

  def regression(_, _), do: {:error, :invalid_regression}

  @spec repaired(Path.t(), String.t(), map(), map()) :: tuple()
  def repaired(path, id, handle, proof) do
    update(path, id, handle, fn state, record ->
      if state.owner == id and record.role in [:integration, :repair] and is_map(state.regression) and
           record.scope == state.regression.scope and proof[:regression_id] == state.regression.id and
           proof[:scope] == state.regression.scope and proof[:completed] == true and
           proof[:exit_status] == 0 and is_binary(proof[:tested_revision]) and proof[:tested_revision] != "" and
           is_binary(proof[:receipt]) and proof[:receipt] != "" do
        {:ok, :repaired, %{state | regression: nil}}
      else
        {:error, :unproven_repair}
      end
    end)
  end

  @spec status(Path.t()) :: tuple()
  def status(path) do
    Store.transact(path, fn state ->
      records =
        Enum.map(state.reservations, fn {id, r} ->
          %{issue_id: id, role: r.role, status: r.status, hold: if(r.status == :running, do: :in_flight_or_recovery_required, else: :retry_reserved)}
        end)

      result = %{writers: Enum.count(records, &(&1.role == :writer)), integration_owner: state.owner, regression: state.regression, reservations: records}
      {:ok, result, state}
    end)
  end

  defp create(_state, _id, _role, _scope, resume, _snapshot, _now, _age) when not is_nil(resume),
    do: {:error, :unknown_reservation}

  defp create(state, id, role, scope, nil, snapshot, now, age) do
    with :ok <- owner_available(state, role),
         :ok <- capacity(state, role, scope, snapshot, now, age) do
      record = %{token: token(), session: token(), role: role, scope: scope, status: :running}
      next = put_in(state, [:reservations, id], record)
      next = if role == :writer, do: next, else: %{next | owner: id}
      {:ok, record, next}
    end
  end

  defp resume(state, id, record, role, scope, handle) do
    cond do
      not matches?(record, handle) ->
        {:error, :reservation_mismatch}

      record.role != role or record.scope != scope ->
        {:error, :reservation_role_changed}

      record.status != :idle ->
        {:error, :reservation_in_flight}

      true ->
        next = %{record | session: token(), status: :running}
        {:ok, next, put_in(state, [:reservations, id], next)}
    end
  end

  defp capacity(state, :writer, _scope, snapshot, now, age) do
    with %{version: 1, complete: true, observed_at_ms: observed, deliveries: deliveries} <- snapshot do
      Capacity.check(%Attempt{role: :writer, active_writers: writer_count(state), deliveries: deliveries, regression: not is_nil(state.regression), observed_at_ms: observed, complete: true}, now, age)
      |> normalize()
    else
      _ -> {:error, :incomplete_delivery_state}
    end
  end

  defp capacity(state, :repair, scope, _snapshot, now, age) do
    if match?(%{scope: ^scope}, state.regression) do
      capacity(state, :integration, scope, nil, now, age)
    else
      {:error, :no_matching_regression_to_repair}
    end
  end

  defp capacity(state, :integration, _scope, _snapshot, now, age) do
    Capacity.check(%Attempt{role: :integration, active_writers: writer_count(state), deliveries: [], regression: not is_nil(state.regression), observed_at_ms: now, complete: true}, now, age)
    |> normalize()
  end

  defp owner_available(_state, :writer), do: :ok
  defp owner_available(%{owner: nil}, _role), do: :ok
  defp owner_available(_, _), do: {:error, :integration_owned}
  defp writer_count(state), do: Enum.count(state.reservations, fn {_, r} -> r.role == :writer end)
  defp normalize(:ok), do: :ok
  defp normalize({:reject, reason}), do: {:error, reason}
  defp normalize(other), do: other
  defp token, do: Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

  defp update(path, id, handle, fun) do
    Store.transact(path, fn state ->
      record = Map.get(state.reservations, id)
      if matches?(record, handle), do: fun.(state, record), else: {:error, :reservation_mismatch}
    end)
  end

  defp matches?(%{token: token, session: session}, %{token: token, session: session}), do: true
  defp matches?(_, _), do: false
end
