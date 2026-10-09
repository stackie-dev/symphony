defmodule SymphonyElixir.Dispatch.Admission.Store do
  @moduledoc "Filesystem-serialized admission journal. Missing, corrupt or abandoned locks never become empty capacity."

  @spec transact(Path.t(), (map() -> {:ok, term(), map()} | {:error, term()})) :: tuple()
  def transact(path, fun) when is_binary(path) and is_function(fun, 1) do
    with :ok <- initialize(path),
         :ok <- lock(path) do
      try do
        with {:ok, state} <- load(path),
             {:ok, result, next} <- fun.(state),
             :ok <- persist(path, state, next) do
          {:ok, result}
        end
      after
        File.rmdir(Path.join(path, "lock"))
      end
    end
  rescue
    _ -> {:error, :journal_unavailable}
  end

  def transact(_, _), do: {:error, :invalid_authority}

  defp initialize(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.mkdir(path) do
        :ok ->
          with :ok <- File.chmod(path, 0o700),
               :ok <- save(path, %{version: 1, reservations: %{}, owner: nil, regression: nil, selected_issue_ids: []}) do
            :ok
          end

        {:error, :eexist} ->
          case File.lstat(path) do
            {:ok, %{type: :directory}} -> :ok
            _ -> {:error, :invalid_authority}
          end

        _ ->
          {:error, :journal_unavailable}
      end
    end
  end

  defp lock(path) do
    case File.mkdir(Path.join(path, "lock")) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :journal_busy}
      _ -> {:error, :journal_unavailable}
    end
  end

  defp load(path) do
    file = Path.join(path, "admission.term")

    with {:ok, %{type: :regular}} <- File.lstat(file),
         {:ok, bytes} <- File.read(file) do
      state = :erlang.binary_to_term(bytes, [:safe])
      if valid?(state), do: {:ok, state}, else: {:error, :corrupt_journal}
    else
      _ -> {:error, :missing_journal}
    end
  rescue
    _ -> {:error, :corrupt_journal}
  end

  defp valid?(%{version: 1, reservations: reservations, owner: owner, regression: regression, selected_issue_ids: ids})
       when is_map(reservations) and is_list(ids) do
    Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0)) and
      Enum.all?(reservations, fn {id, record} ->
        is_binary(id) and byte_size(id) > 0 and valid_record?(record)
      end) and valid_owner?(owner, reservations) and
      (is_nil(regression) or match?(%{id: id, scope: scope} when is_binary(id) and is_binary(scope), regression))
  end

  defp valid?(_), do: false

  defp valid_record?(%{token: token, session: session, role: role, status: status, scope: scope}) do
    is_binary(token) and byte_size(token) >= 32 and is_binary(session) and byte_size(session) >= 32 and
      role in [:writer, :integration, :repair] and status in [:running, :idle] and is_binary(scope)
  end

  defp valid_record?(_), do: false
  defp valid_owner?(nil, reservations), do: Enum.all?(reservations, fn {_, r} -> r.role == :writer end)

  defp valid_owner?(id, reservations) when is_binary(id) do
    case Map.get(reservations, id) do
      %{role: role} when role in [:integration, :repair] ->
        Enum.all?(reservations, fn {other, r} -> r.role == :writer or other == id end)

      _ ->
        false
    end
  end

  defp valid_owner?(_, _), do: false

  defp persist(_path, state, state), do: :ok
  defp persist(path, _state, next), do: save(path, next)

  defp save(path, state) do
    tmp = Path.join(path, "pending-" <> Base.encode16(:crypto.strong_rand_bytes(16)))

    result =
      with {:ok, file} <- File.open(tmp, [:write, :binary, :exclusive]) do
        try do
          with :ok <- File.chmod(tmp, 0o600),
               :ok <- IO.binwrite(file, :erlang.term_to_binary(state)),
               :ok <- :file.sync(file),
               :ok <- File.rename(tmp, Path.join(path, "admission.term")) do
            :ok
          end
        after
          File.close(file)
        end
      end

    File.rm(tmp)

    case result do
      :ok -> :ok
      _ -> {:error, :journal_persistence}
    end
  end
end
