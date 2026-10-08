defmodule SymphonyElixir.Dispatch.Backpressure.Fixtures do
  @moduledoc "Controlled complete empty-artifact read boundary for original orchestrator tests; real delivery persistence and admission remain in use."

  @spec reader_options() :: keyword()
  def reader_options do
    [
      tracker_read: fn query, %{id: id} ->
        field = if String.contains?(query, "attachments("), do: "attachments", else: "comments"

        {:ok,
         %{
           "data" => %{"issue" => %{"id" => id, "updatedAt" => "1970-01-01T00:00:00.001Z", "description" => "", field => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
         }}
      end,
      pr_read: fn _, _ -> raise "unexpected artifact read in empty-delivery fixture" end
    ]
  end
end
