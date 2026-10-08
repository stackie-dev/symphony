defmodule SymphonyElixir.Dispatch.DeliveryState.Model do
  @moduledoc "Canonical monotonic delivery reconciliation; only native terminal evidence clears outstanding work."
  alias SymphonyElixir.Dispatch.DeliveryState.Snapshot

  @spec new() :: map()
  def new, do: %{"version" => 1, "observed_at_ms" => nil, "entries" => [], "sources" => %{}}

  @spec validate(term()) :: :ok | {:error, {:delivery_state, :corrupt}}
  def validate(%{"version" => 1, "observed_at_ms" => time, "entries" => entries, "sources" => sources})
      when is_integer(time) and time >= 0 and is_list(entries) and is_map(sources) do
    keys = Enum.map(entries, &key/1)

    if Enum.all?(entries, &(valid_entry?(&1) and &1["revision_ms"] <= time)) and length(Enum.uniq(keys)) == length(keys) and
         Enum.all?(sources, fn {id, revision} -> is_binary(id) and is_integer(revision) and revision >= 0 and revision <= time end) do
      :ok
    else
      error(:corrupt)
    end
  end

  def validate(_), do: error(:corrupt)

  @spec fresh(map(), term(), term()) :: :ok | {:error, {:delivery_state, atom()}}
  def fresh(state, now, age) when is_integer(now) and now >= 0 and is_integer(age) and age >= 0 do
    cond do
      state["observed_at_ms"] > now -> error(:future)
      now - state["observed_at_ms"] > age -> error(:stale)
      true -> :ok
    end
  end

  def fresh(_, _, _), do: error(:invalid_options)

  @spec clock(map(), non_neg_integer()) :: :ok | {:error, {:delivery_state, atom()}}
  def clock(%{"observed_at_ms" => nil}, _now), do: :ok
  def clock(state, now), do: if(state["observed_at_ms"] > now, do: error(:stale_source), else: :ok)

  @spec snapshot(map()) :: Snapshot.t()
  def snapshot(state) do
    deliveries = state["entries"] |> Enum.filter(& &1["outstanding"]) |> Enum.map(&key/1) |> Enum.sort()
    %Snapshot{deliveries: deliveries, observed_at_ms: state["observed_at_ms"], sources: state["sources"]}
  end

  @spec repository?(term()) :: boolean()
  def repository?(value) when is_binary(value) do
    String.match?(value, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) and
      Enum.all?(String.split(value, "/"), &(&1 not in [".", ".."]))
  end

  def repository?(_), do: false

  @spec key(map()) :: {String.t(), String.t()}
  def key(entry) when is_map(entry), do: {entry["repository"], entry["number"]}
  def key(_), do: {nil, nil}

  @spec reconcile(map(), [map()], map(), non_neg_integer()) :: {:ok, map()} | {:error, {:delivery_state, atom()}}
  def reconcile(previous, observations, sources, now) do
    old = Map.new(previous["entries"], &{key(&1), &1})

    with :ok <- source_revisions(previous["sources"], sources),
         {:ok, entries} <- merge_entries(observations, old, now) do
      {:ok, %{"version" => 1, "observed_at_ms" => now, "entries" => entries, "sources" => Map.merge(previous["sources"], sources)}}
    end
  end

  @spec decode_pr(String.t(), String.t(), term()) :: {:ok, map()} | {:error, {:delivery_state, atom()}}
  def decode_pr(
        repo,
        number,
        %{"number" => native, "state" => state, "draft" => draft, "merged" => merged, "updated_at" => updated, "head" => %{"sha" => sha}, "base" => %{"repo" => %{"full_name" => actual}}} = pr
      )
      when is_integer(native) and is_boolean(draft) and is_boolean(merged) and is_binary(sha) and sha != "" and is_binary(actual) do
    with true <- Integer.to_string(native) == number and String.downcase(actual) == repo,
         {:ok, revision} <- timestamp(updated),
         {:ok, terminal, terminal_at} <- terminal(pr, state, merged, revision) do
      {:ok,
       %{
         "repository" => repo,
         "number" => number,
         "revision_ms" => revision,
         "head" => sha,
         "state" => state,
         "draft" => draft,
         "terminal" => terminal,
         "terminal_at_ms" => terminal_at,
         "outstanding" => state == "open" and not draft
       }}
    else
      _ -> error(:incomplete_artifact)
    end
  end

  def decode_pr(_, _, _), do: error(:incomplete_artifact)

  @spec timestamp(term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} ->
        milliseconds = DateTime.to_unix(time, :millisecond)
        if milliseconds >= 0, do: {:ok, milliseconds}, else: {:error, :invalid_time}

      _ ->
        {:error, :invalid_time}
    end
  end

  def timestamp(_), do: {:error, :invalid_time}

  defp terminal(pr, "closed", true, revision) do
    with {:ok, merged_at} <- timestamp(pr["merged_at"]),
         {:ok, closed_at} <- timestamp(pr["closed_at"]),
         true <- merged_at <= revision and closed_at <= revision do
      {:ok, "merged", merged_at}
    else
      _ -> {:error, :invalid_terminal}
    end
  end

  defp terminal(pr, "closed", false, revision) do
    with {:ok, closed_at} <- timestamp(pr["closed_at"]),
         true <- closed_at <= revision and is_nil(pr["merged_at"]) do
      {:ok, "withdrawn", closed_at}
    else
      _ -> {:error, :invalid_terminal}
    end
  end

  defp terminal(pr, "open", false, _revision) do
    if is_nil(pr["closed_at"]) and is_nil(pr["merged_at"]), do: {:ok, nil, nil}, else: {:error, :invalid_terminal}
  end

  defp terminal(_, _, _, _), do: {:error, :invalid_terminal}

  defp source_revisions(old, new) do
    if Enum.all?(new, fn {id, revision} -> revision >= Map.get(old, id, 0) end), do: :ok, else: error(:stale_source)
  end

  defp merge_entries(observations, old, now) do
    Enum.reduce_while(observations, {:ok, old}, fn current, {:ok, acc} ->
      case merge_entry(Map.get(acc, key(current)), current, now) do
        {:ok, next} -> {:cont, {:ok, Map.put(acc, key(next), next)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, entries |> Map.values() |> Enum.sort_by(&key/1)}
      error -> error
    end
  end

  defp merge_entry(old, current, now) do
    cond do
      current["revision_ms"] > now ->
        error(:future)

      old != nil and current["revision_ms"] < old["revision_ms"] ->
        error(:stale_source)

      old != nil and current["revision_ms"] == old["revision_ms"] and
          Map.drop(current, ["outstanding"]) != Map.drop(old, ["outstanding"]) ->
        error(:conflicting_source)

      current["terminal"] != nil ->
        {:ok, Map.put(current, "outstanding", false)}

      true ->
        {:ok, Map.put(current, "outstanding", current["outstanding"] or (old != nil and old["outstanding"]))}
    end
  end

  defp valid_entry?(entry) when is_map(entry) do
    repository?(entry["repository"]) and entry["repository"] == String.downcase(entry["repository"]) and
      is_binary(entry["number"]) and String.match?(entry["number"], ~r/^[1-9][0-9]*$/) and
      is_integer(entry["revision_ms"]) and entry["revision_ms"] >= 0 and
      is_binary(entry["head"]) and entry["head"] != "" and is_boolean(entry["draft"]) and
      is_boolean(entry["outstanding"]) and entry["state"] in ["open", "closed"] and
      entry["terminal"] in [nil, "merged", "withdrawn"] and
      ((entry["state"] == "open" and entry["terminal"] == nil and entry["terminal_at_ms"] == nil) or
         (entry["state"] == "closed" and entry["terminal"] in ["merged", "withdrawn"] and entry["outstanding"] == false and
            is_integer(entry["terminal_at_ms"]) and entry["terminal_at_ms"] >= 0 and entry["terminal_at_ms"] <= entry["revision_ms"]))
  end

  defp valid_entry?(_), do: false
  defp error(reason), do: {:error, {:delivery_state, reason}}
end
