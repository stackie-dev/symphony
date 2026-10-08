defmodule SymphonyElixir.Dispatch.DeliveryState.Source do
  @moduledoc "Read-only selected-issue link discovery and authoritative PR reads using existing clients."
  alias SymphonyElixir.Dispatch.DeliveryState.Model
  alias SymphonyElixir.{GitHub, Linear}

  @pr_url ~r{https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)(?=$|[^0-9A-Za-z])}

  @spec options(keyword()) :: {:ok, map()} | {:error, {:delivery_state, atom()}}
  def options(opts) do
    ids = Keyword.get(opts, :issue_ids)
    repos = Keyword.get(opts, :repositories)
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
    age = Keyword.get(opts, :max_age_ms, 60_000)
    tracker = Keyword.get(opts, :tracker_read, &Linear.Client.graphql/2)
    github_options = Keyword.get(opts, :github_options, [])
    prs = Keyword.get(opts, :pr_read, fn repo, number -> read_pr(repo, number, github_options) end)

    if is_list(ids) and Enum.all?(ids, &present?/1) and is_list(repos) and
         Enum.all?(repos, &Model.repository?/1) and
         is_integer(now) and now >= 0 and is_integer(age) and age >= 0 and
         is_function(tracker, 2) and is_function(prs, 2) and is_list(github_options) do
      {:ok, %{issue_ids: Enum.uniq(ids), repositories: MapSet.new(repos, &String.downcase/1), now_ms: now, max_age_ms: age, tracker_read: tracker, pr_read: prs}}
    else
      error(:invalid_options)
    end
  end

  @spec discover(map()) :: {:ok, MapSet.t(), map()} | {:error, {:delivery_state, atom()}}
  def discover(settings) do
    Enum.reduce_while(settings.issue_ids, {:ok, MapSet.new(), %{}}, fn id, {:ok, refs, sources} ->
      with {:ok, attachments, revision, description} <- connection(id, "attachments", settings.tracker_read),
           {:ok, comments, ^revision, ^description} <- connection(id, "comments", settings.tracker_read),
           true <- revision <= settings.now_ms,
           {:ok, texts} <- link_texts(attachments, comments, description) do
        linked = texts |> Enum.flat_map(&links(&1, settings.repositories)) |> MapSet.new()
        {:cont, {:ok, MapSet.union(refs, linked), Map.put(sources, id, revision)}}
      else
        _ -> {:halt, error(:incomplete_tracker)}
      end
    end)
  end

  @spec observe(MapSet.t(), [map()], map()) :: {:ok, [map()]} | {:error, {:delivery_state, atom()}}
  def observe(refs, known, settings) do
    refs = Enum.reduce(known, refs, &MapSet.put(&2, Model.key(&1)))

    refs
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {repo, number}, {:ok, acc} ->
      with true <- MapSet.member?(settings.repositories, repo),
           {:ok, payload} <- settings.pr_read.(repo, number),
           {:ok, entry} <- Model.decode_pr(repo, number, payload) do
        {:cont, {:ok, [entry | acc]}}
      else
        _ -> {:halt, error(:incomplete_artifact)}
      end
    end)
  end

  defp read_pr(repo, number, opts) do
    with {:ok, %{status: 200, body: body}} <- GitHub.Client.request("GET", "/repos/#{repo}/pulls/#{number}", %{}, nil, opts) do
      {:ok, body}
    else
      _ -> error(:incomplete_artifact)
    end
  end

  defp connection(id, field, reader), do: page(id, field, reader, nil, MapSet.new(), [], nil, 100)
  defp page(_, _, _, _, _, _, _, 0), do: error(:incomplete_tracker)

  defp page(id, field, reader, cursor, seen, acc, baseline, remaining) do
    selection = if field == "attachments", do: "url", else: "body"

    query = """
    query DeliveryLinks($id: String!, $after: String) {
      issue(id: $id) {
        id updatedAt description
        #{field}(first: 100, after: $after) {
          nodes { #{selection} } pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    with {:ok, payload} <- reader.(query, %{id: id, after: cursor}),
         {:ok, nodes, next?, next, revision, description} <- decode(payload, id, field),
         true <- baseline == nil or baseline == {revision, description} do
      acc = [nodes | acc]

      cond do
        not next? -> {:ok, acc |> Enum.reverse() |> Enum.concat(), revision, description}
        not present?(next) or MapSet.member?(seen, next) -> error(:incomplete_tracker)
        true -> page(id, field, reader, next, MapSet.put(seen, next), acc, {revision, description}, remaining - 1)
      end
    else
      _ -> error(:incomplete_tracker)
    end
  end

  defp decode(%{"errors" => errors}, _, _) when errors != [], do: error(:incomplete_tracker)

  defp decode(%{"data" => %{"issue" => %{"id" => id, "updatedAt" => updated} = issue}}, id, field) do
    with %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next?, "endCursor" => cursor}} <- issue[field],
         true <- is_list(nodes) and is_boolean(next?),
         {:ok, revision} <- Model.timestamp(updated),
         true <- is_nil(issue["description"]) or is_binary(issue["description"]) do
      {:ok, nodes, next?, cursor, revision, issue["description"] || ""}
    else
      _ -> error(:incomplete_tracker)
    end
  end

  defp decode(_, _, _), do: error(:incomplete_tracker)

  defp link_texts(attachments, comments, description) do
    urls = Enum.map(attachments, fn row -> if is_map(row), do: row["url"] end)
    bodies = Enum.map(comments, fn row -> if is_map(row), do: row["body"] end)
    texts = [description | urls ++ bodies]
    if Enum.all?(texts, &is_binary/1), do: {:ok, texts}, else: error(:incomplete_tracker)
  end

  defp links(text, allowed) do
    Regex.scan(@pr_url, text)
    |> Enum.flat_map(fn [_, repo, number] ->
      canonical = String.downcase(repo)
      if MapSet.member?(allowed, canonical), do: [{canonical, number}], else: []
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp error(reason), do: {:error, {:delivery_state, reason}}
end
