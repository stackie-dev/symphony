defmodule SymphonyElixir.Linear.AdmissionMetadata do
  @moduledoc "Complete, fail-closed Linear observations; preserves existing non-admission issue fields."
  alias SymphonyElixir.Dispatch.Snapshot
  alias SymphonyElixir.Linear.AdmissionConnection
  alias SymphonyElixir.Tracker.Issue

  @query """
  query AdmissionIssue($id: String!) {
    issue(id: $id) { id identifier state { name } assignee { id } project { id } }
  }
  """

  @spec fetch(Issue.t(), String.t(), String.t(), AdmissionConnection.reader(), (-> non_neg_integer())) ::
          {:ok, Snapshot.t()} | {:error, atom()}
  def fetch(%Issue{id: id} = original, organisation, route, reader, clock \\ fn -> System.system_time(:millisecond) end) do
    observed_at_ms = clock.()

    with {:ok, raw} <- reader.(@query, %{id: id}),
         {:ok, core} <- core(raw, id),
         {:ok, labels} <- AdmissionConnection.fetch(id, :labels, reader),
         {:ok, children} <- AdmissionConnection.fetch(id, :children, reader),
         {:ok, relations} <- AdmissionConnection.fetch(id, :inverseRelations, reader),
         {:ok, labels} <- strings(labels, "name"),
         {:ok, children} <- strings(children, "id"),
         {:ok, blockers} <- blockers(relations) do
      issue = %{
        original
        | state: core.state,
          identifier: core.identifier,
          assignee_id: core.assignee,
          labels: labels,
          blocked_by: blockers
      }

      repository = labels |> Enum.find("repo:", &String.starts_with?(&1, "repo:")) |> String.replace_prefix("repo:", "")

      {:ok,
       %Snapshot{
         scope: {"linear", organisation},
         canonical_issue_id: id,
         issue: issue,
         project_id: core.project,
         child_ids: children,
         repository: repository,
         route: route,
         observed_at_ms: observed_at_ms,
         complete: true
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :incomplete_metadata}
    end
  end

  defp core(%{"errors" => errors}, _id) when errors != [], do: {:error, :graphql_errors}

  defp core(%{"data" => %{"issue" => %{"id" => other}}}, id) when other != id,
    do: {:error, :issue_identity_changed}

  defp core(
         %{
           "data" => %{
             "issue" => %{
               "id" => id,
               "identifier" => identifier,
               "state" => %{"name" => state},
               "assignee" => assignee,
               "project" => project
             }
           }
         },
         id
       )
       when is_binary(id) and is_binary(identifier) and is_binary(state) do
    with {:ok, assignee} <- optional_id(assignee), {:ok, project} <- optional_id(project) do
      {:ok, %{identifier: identifier, state: state, assignee: assignee, project: project}}
    end
  end

  defp core(_, _), do: {:error, :incomplete_metadata}
  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp optional_id(_), do: {:error, :incomplete_metadata}

  defp strings(nodes, key) do
    Enum.reduce_while(nodes, {:ok, []}, fn
      node, {:ok, acc} when is_map(node) ->
        case node[key] do
          value when is_binary(value) and value != "" -> {:cont, {:ok, [value | acc]}}
          _ -> {:halt, {:error, :incomplete_nodes}}
        end

      _, _ ->
        {:halt, {:error, :incomplete_nodes}}
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp blockers(relations) do
    Enum.reduce_while(relations, {:ok, %{}}, fn relation, {:ok, acc} -> merge_blocker(relation, acc) end)
    |> case do
      {:ok, values} -> {:ok, values |> Map.values() |> Enum.sort_by(& &1.id)}
      error -> error
    end
  end

  defp merge_blocker(%{"type" => "blocks", "issue" => %{"id" => id, "state" => %{"name" => state}}}, acc)
       when is_binary(id) and id != "" and is_binary(state) and state != "" do
    blocker = %{id: id, state: state}

    case Map.get(acc, id) do
      nil -> {:cont, {:ok, Map.put(acc, id, blocker)}}
      ^blocker -> {:cont, {:ok, acc}}
      _ -> {:halt, {:error, :inconsistent_blocker}}
    end
  end

  defp merge_blocker(%{"type" => "blocks"}, _acc), do: {:halt, {:error, :incomplete_blocker}}
  defp merge_blocker(%{"type" => type}, acc) when is_binary(type), do: {:cont, {:ok, acc}}
  defp merge_blocker(_, _acc), do: {:halt, {:error, :incomplete_relation}}
end
