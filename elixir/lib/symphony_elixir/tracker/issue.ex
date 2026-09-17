defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized work item representation used by the orchestrator.

  `id` is the stable dispatch identity for the configured tracker scope. It may
  differ from a provider's underlying issue ID when the scheduled item is a
  board or project entry. `native_ref` carries non-secret provider identifiers
  needed by provider-native agent tools. `identifier` remains the human-readable
  value used to derive the workspace key and must be unique within that scope.
  """

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    dispatchable: false,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()],
          dispatchable: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{dispatchable: true, labels: labels}, required_labels)
      when is_list(labels) and is_list(required_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)

    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1))) and
      match?({:ok, _platform}, required_platform(%__MODULE__{labels: labels}))
  end

  def routable?(%__MODULE__{}, _required_labels), do: false

  @spec required_platform(t()) :: {:ok, nil | String.t()} | {:error, :invalid_platform_labels}
  def required_platform(%__MODULE__{labels: labels}) when is_list(labels) do
    platforms =
      labels
      |> Enum.map(&normalize_label/1)
      |> Enum.filter(&String.starts_with?(&1, "platform-"))
      |> Enum.uniq()

    case platforms do
      [] -> {:ok, nil}
      ["platform-linux"] -> {:ok, "linux"}
      ["platform-macos"] -> {:ok, "macos"}
      ["platform-windows"] -> {:ok, "windows"}
      _ -> {:error, :invalid_platform_labels}
    end
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end
end
