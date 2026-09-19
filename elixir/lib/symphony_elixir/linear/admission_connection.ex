defmodule SymphonyElixir.Linear.AdmissionConnection do
  @moduledoc false
  @selections %{
    labels: "name",
    children: "id",
    inverseRelations: "type issue { id state { name } }"
  }
  @type reader :: (String.t(), map() -> {:ok, map()} | {:error, term()})

  @spec fetch(String.t(), :labels | :children | :inverseRelations, reader()) :: {:ok, [map()]} | {:error, atom()}
  def fetch(id, field, reader), do: page(id, field, reader, nil, MapSet.new(), [], 100)

  defp page(_id, _field, _reader, _cursor, _seen, _acc, 0), do: {:error, :pagination_limit}

  defp page(id, field, reader, cursor, seen, acc, remaining) do
    query = """
    query AdmissionConnection($id: String!, $after: String) {
      issue(id: $id) { id #{field}(first: 100, after: $after) {
        nodes { #{@selections[field]} } pageInfo { hasNextPage endCursor }
      } }
    }
    """

    with {:ok, body} <- reader.(query, %{id: id, after: cursor}),
         {:ok, nodes, next?, next} <- decode(body, id, Atom.to_string(field)) do
      advance(id, field, reader, next?, next, seen, [nodes | acc], remaining)
    else
      {:error, _} -> {:error, :incomplete_connection}
      _ -> {:error, :incomplete_connection}
    end
  end

  defp advance(_id, _field, _reader, false, _next, _seen, acc, _remaining) do
    {:ok, acc |> Enum.reverse() |> Enum.concat()}
  end

  defp advance(id, field, reader, true, next, seen, acc, remaining) do
    cond do
      not is_binary(next) or next == "" -> {:error, :incomplete_connection}
      MapSet.member?(seen, next) -> {:error, :pagination_cycle}
      true -> page(id, field, reader, next, MapSet.put(seen, next), acc, remaining - 1)
    end
  end

  defp decode(%{"errors" => errors}, _id, _field) when errors != [], do: {:error, :graphql_errors}

  defp decode(%{"data" => %{"issue" => %{"id" => id} = issue}}, id, field) do
    case issue[field] do
      %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next?, "endCursor" => cursor}}
      when is_list(nodes) and is_boolean(next?) ->
        {:ok, nodes, next?, cursor}

      _ ->
        {:error, :incomplete_connection}
    end
  end

  defp decode(_, _, _), do: {:error, :incomplete_connection}
end
