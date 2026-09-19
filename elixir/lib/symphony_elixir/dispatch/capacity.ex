defmodule SymphonyElixir.Dispatch.Capacity do
  @moduledoc "Pure admission counts. This does not reserve a slot or grant an integration lease."
  alias SymphonyElixir.Dispatch.{Attempt, Validation}

  @type result :: :ok | {:reject, atom()} | {:error, atom() | tuple()}

  @spec check(Attempt.t(), non_neg_integer(), non_neg_integer()) :: result()
  def check(attempt, now_ms, max_age_ms)
      when is_integer(now_ms) and now_ms >= 0 and is_integer(max_age_ms) and max_age_ms >= 0 do
    with :ok <- Validation.attempt(attempt) do
      cond do
        attempt.observed_at_ms > now_ms -> {:reject, :future_capacity}
        now_ms - attempt.observed_at_ms > max_age_ms -> {:reject, :stale_capacity}
        true -> admit_role(attempt)
      end
    end
  end

  def check(_, _, _), do: {:error, :invalid_freshness_policy}

  defp admit_role(%Attempt{role: :integration}), do: :ok
  defp admit_role(%Attempt{role: :repair, regression: true}), do: :ok
  defp admit_role(%Attempt{role: :repair}), do: {:reject, :no_regression_to_repair}

  defp admit_role(%Attempt{role: :writer} = attempt) do
    cond do
      attempt.regression -> {:reject, :integration_regression}
      attempt.active_writers >= 2 -> {:reject, :writer_capacity}
      MapSet.size(MapSet.new(attempt.deliveries)) >= 2 -> {:reject, :delivery_backpressure}
      true -> :ok
    end
  end
end
