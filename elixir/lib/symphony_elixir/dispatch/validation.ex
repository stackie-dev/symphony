defmodule SymphonyElixir.Dispatch.Validation do
  @moduledoc false
  alias SymphonyElixir.Dispatch.{Attempt, Snapshot, Worker}
  alias SymphonyElixir.Tracker.Issue
  @type result :: :ok | {:error, {:incomplete | :invalid, :snapshot | :worker | :attempt}}

  @spec snapshot(term()) :: result()
  def snapshot(%Snapshot{version: version}) when version != 1, do: invalid(:snapshot)
  def snapshot(%Snapshot{complete: false}), do: incomplete(:snapshot)

  def snapshot(%Snapshot{issue: %Issue{} = issue} = value) do
    required = [
      value.canonical_issue_id,
      value.child_ids,
      value.repository,
      value.route,
      value.observed_at_ms,
      value.scope,
      issue.id,
      issue.state,
      issue.labels,
      issue.blocked_by
    ]

    cond do
      Enum.any?(required, &is_nil/1) -> incomplete(:snapshot)
      not is_list(issue.blocked_by) -> invalid(:snapshot)
      Enum.any?(issue.blocked_by, &(is_map(&1) and is_nil(Map.get(&1, :state)))) -> incomplete(:snapshot)
      not valid_snapshot?(value) -> invalid(:snapshot)
      true -> :ok
    end
  end

  def snapshot(%Snapshot{issue: nil}), do: incomplete(:snapshot)
  def snapshot(nil), do: incomplete(:snapshot)
  def snapshot(_), do: invalid(:snapshot)

  @spec worker(term()) :: result()
  def worker(%Worker{version: version}) when version != 1, do: invalid(:worker)

  def worker(%Worker{} = value) do
    cond do
      Enum.any?([value.id, value.os, value.available, value.slots, value.observed_at_ms], &is_nil/1) ->
        incomplete(:worker)

      not text?(value.id) or value.os not in [:linux, :macos, :windows, :unknown] ->
        invalid(:worker)

      not is_boolean(value.available) or not count?(value.slots) or not count?(value.observed_at_ms) ->
        invalid(:worker)

      true ->
        :ok
    end
  end

  def worker(nil), do: incomplete(:worker)
  def worker(_), do: invalid(:worker)

  @spec attempt(term()) :: result()
  def attempt(%Attempt{version: version}) when version != 1, do: invalid(:attempt)
  def attempt(%Attempt{complete: false}), do: incomplete(:attempt)

  def attempt(%Attempt{} = value) do
    cond do
      Enum.any?([value.role, value.active_writers, value.deliveries, value.regression, value.observed_at_ms], &is_nil/1) ->
        incomplete(:attempt)

      not valid_attempt?(value) ->
        invalid(:attempt)

      true ->
        :ok
    end
  end

  def attempt(nil), do: incomplete(:attempt)
  def attempt(_), do: invalid(:attempt)

  defp valid_snapshot?(value) do
    strings = [value.canonical_issue_id, value.issue.id, value.issue.state, value.repository, value.route]

    value.complete == true and pair?(value.scope) and Enum.all?(strings, &text?/1) and
      optional_text?(value.project_id) and optional_text?(value.issue.assignee_id) and
      valid_collections?(value) and count?(value.observed_at_ms)
  end

  defp valid_collections?(value) do
    list_of?(value.child_ids, &text?/1) and list_of?(value.issue.labels, &text?/1) and
      list_of?(value.issue.blocked_by, &blocker?/1)
  end

  defp valid_attempt?(value) do
    counts = [value.active_writers, value.observed_at_ms]
    hosts = [value.preferred_host, value.integration_owner]

    value.complete == true and value.role in [:writer, :integration, :repair] and
      Enum.all?(counts, &count?/1) and Enum.all?(hosts, &optional_text?/1) and
      is_boolean(value.regression) and list_of?(value.deliveries, &pair?/1)
  end

  defp text?(value), do: is_binary(value) and byte_size(String.trim(value)) > 0
  defp optional_text?(value), do: is_nil(value) or text?(value)
  defp count?(value), do: is_integer(value) and value >= 0
  defp pair?({left, right}), do: text?(left) and text?(right)
  defp pair?(_), do: false
  defp list_of?(value, predicate), do: is_list(value) and Enum.all?(value, predicate)
  defp blocker?(%{id: id, state: state}), do: text?(id) and text?(state)
  defp blocker?(_), do: false
  defp invalid(kind), do: {:error, {:invalid, kind}}
  defp incomplete(kind), do: {:error, {:incomplete, kind}}
end
