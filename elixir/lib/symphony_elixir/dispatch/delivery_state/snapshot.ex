defmodule SymphonyElixir.Dispatch.DeliveryState.Snapshot do
  @moduledoc """
  Complete canonical delivery observation. This is not an admission permission.

  `sources` holds non-secret native tracker revision metadata. `deliveries` is
  deduplicated by repository and native PR number, independent of ticket state.
  """
  defstruct [:observed_at_ms, deliveries: [], sources: %{}, version: 1, complete: true]

  @type t :: %__MODULE__{
          version: 1,
          complete: boolean(),
          observed_at_ms: non_neg_integer(),
          deliveries: [{String.t(), String.t()}],
          sources: map()
        }
end
