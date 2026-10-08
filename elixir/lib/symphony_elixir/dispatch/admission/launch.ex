defmodule SymphonyElixir.Dispatch.Admission.Launch do
  @moduledoc "Trusted workflow role selection and actual pre-launch admission. A failed refresh never falls back to persisted delivery data."
  alias SymphonyElixir.Dispatch.{Admission, DeliveryState}

  @spec config(map(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def config(raw, base) when is_map(raw) do
    with %{"repositories" => repos, "issue_ids" => ids} <- raw,
         true <- is_list(repos) and repos != [] and Enum.all?(repos, &nonempty?/1),
         true <- is_list(ids) and Enum.all?(ids, &nonempty?/1),
         directory when is_binary(directory) <- Map.get(raw, "state_dir", ".symphony-dispatch"),
         true <- nonempty?(directory),
         age when is_integer(age) and age >= 0 <- Map.get(raw, "max_age_ms", 60_000),
         roles when is_map(roles) <- Map.get(raw, "integration_scopes", %{}),
         repairs when is_map(repairs) <- Map.get(raw, "repair_scopes", %{}),
         true <- Enum.all?(Map.to_list(roles) ++ Map.to_list(repairs), fn {id, scope} -> nonempty?(id) and nonempty?(scope) end),
         true <- MapSet.disjoint?(MapSet.new(Map.keys(roles)), MapSet.new(Map.keys(repairs))) do
      path = Path.expand(directory, base)
      {:ok, %{path: path, delivery_path: path <> "-deliveries.json", repositories: repos, issue_ids: ids, max_age_ms: age, integration_scopes: roles, repair_scopes: repairs}}
    else
      _ -> {:error, :invalid_dispatch_config}
    end
  end

  def config(_, _), do: {:error, :missing_dispatch_config}

  @spec acquire(tuple(), String.t(), map() | nil) :: tuple()
  def acquire({:ok, config}, id, resume) do
    {role, scope} = role(config, id)

    with {:ok, ids} <- Admission.selection(config.path, id),
         config = %{config | issue_ids: Enum.uniq(config.issue_ids ++ ids)},
         {:ok, snapshot} <- delivery(config, role, resume) do
      Admission.reserve(config.path, id, role, scope, resume, snapshot, System.system_time(:millisecond), config.max_age_ms)
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    :exit, _ -> {:error, :admission_unavailable}
  end

  def acquire({:error, reason}, _, _), do: {:error, reason}

  @spec stopped(tuple(), String.t(), map() | nil) :: tuple()
  def stopped({:ok, config}, id, handle) when is_map(handle), do: Admission.stopped(config.path, id, handle)
  def stopped(_, _, _), do: {:error, :missing_reservation}

  @spec release(tuple(), String.t(), map() | nil) :: tuple()
  def release({:ok, config}, id, handle) when is_map(handle), do: Admission.release(config.path, id, handle)
  def release(_, _, _), do: {:error, :missing_reservation}

  @spec recover(tuple(), String.t(), map(), map()) :: tuple()
  def recover({:ok, config}, id, handle, proof), do: Admission.recover(config.path, id, handle, proof)
  def recover({:error, reason}, _, _, _), do: {:error, reason}

  @spec status(tuple()) :: tuple()
  def status({:ok, config}), do: Admission.status(config.path)
  def status({:error, reason}), do: {:error, reason}

  defp role(config, id) do
    cond do
      Map.has_key?(config.integration_scopes, id) -> {:integration, config.integration_scopes[id]}
      Map.has_key?(config.repair_scopes, id) -> {:repair, config.repair_scopes[id]}
      true -> {:writer, ""}
    end
  end

  defp delivery(_config, role, _resume) when role in [:integration, :repair], do: {:ok, nil}
  defp delivery(_config, :writer, resume) when is_map(resume), do: {:ok, nil}

  defp delivery(config, :writer, nil) do
    opts = [repositories: config.repositories, issue_ids: config.issue_ids, max_age_ms: config.max_age_ms]
    # Injection exists only at the reader boundary for real composition tests.
    refresh = Map.get(config, :refresh, &DeliveryState.refresh/2)
    injected = config |> Map.get(:reader_options, []) |> Keyword.take([:tracker_read, :pr_read, :github_options])
    refresh.(config.delivery_path, Keyword.merge(opts, injected))
  end

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
