defmodule SymphonyElixir.Dispatch.CapacityTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Dispatch.{Attempt, Capacity}

  test "new writers stop at two active writers or two distinct pending deliveries" do
    for count <- 0..3 do
      pending = for n <- 1..count//1, do: {"repo", "pr-#{n}"}
      expected = if count < 2, do: :ok, else: {:reject, :delivery_backpressure}
      assert Capacity.check(attempt(deliveries: pending), 100, 20) == expected
      expected = if count < 2, do: :ok, else: {:reject, :writer_capacity}
      assert Capacity.check(attempt(active_writers: count), 100, 20) == expected
    end
  end

  test "duplicate reports count once and repository identities stay distinct" do
    assert :ok = Capacity.check(attempt(deliveries: [{"a", "1"}, {"a", "1"}]), 100, 20)

    assert {:reject, :delivery_backpressure} =
             Capacity.check(attempt(deliveries: [{"a", "1"}, {"b", "1"}]), 100, 20)
  end

  test "integrator and scoped regression repair can drain a saturated queue" do
    saturated = attempt(active_writers: 2, deliveries: [{"a", "1"}, {"a", "2"}], regression: true)
    assert {:reject, :integration_regression} = Capacity.check(saturated, 100, 20)
    assert :ok = Capacity.check(%{saturated | role: :integration}, 100, 20)
    assert :ok = Capacity.check(%{saturated | role: :repair}, 100, 20)

    assert {:reject, :no_regression_to_repair} =
             Capacity.check(attempt(role: :repair), 100, 20)
  end

  test "unknown, future and stale observations reject every new admission including recovery" do
    for role <- [:writer, :integration, :repair] do
      fresh = attempt(role: role, regression: true)
      assert {:error, {:incomplete, :attempt}} = Capacity.check(%{fresh | complete: false}, 100, 20)
      assert {:reject, :stale_capacity} = Capacity.check(%{fresh | observed_at_ms: 79}, 100, 20)
      assert {:reject, :future_capacity} = Capacity.check(%{fresh | observed_at_ms: 101}, 100, 20)
    end

    assert :ok = Capacity.check(attempt(observed_at_ms: 80), 100, 20)
    assert {:error, {:invalid, :attempt}} = Capacity.check(%{}, 100, 20)

    for {now, age} <- [{-1, 20}, {100, -1}, {nil, 20}, {100, "20"}] do
      assert {:error, :invalid_freshness_policy} = Capacity.check(attempt(), now, age)
    end
  end

  test "reconstructed pending merge state remains backpressured until a delivery is removed" do
    pending = attempt(deliveries: [{"repo", "awaiting-merge"}, {"repo", "integrating"}])
    assert {:reject, :delivery_backpressure} = Capacity.check(pending, 100, 20)
    assert :ok = Capacity.check(%{pending | deliveries: [{"repo", "integrating"}]}, 100, 20)
  end

  defp attempt(overrides \\ []) do
    struct!(
      %Attempt{
        role: :writer,
        active_writers: 0,
        deliveries: [],
        regression: false,
        observed_at_ms: 100,
        complete: true
      },
      overrides
    )
  end
end
