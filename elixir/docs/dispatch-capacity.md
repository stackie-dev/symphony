# Dispatch capacity policy

`Dispatch.Capacity.check(attempt, now_ms, max_age_ms)` consumes the version-1
`Dispatch.Attempt` observation. It returns `:ok`, `{:reject, reason}`, or a
structural/freshness configuration error. Time is supplied explicitly in Unix
milliseconds. The maximum age is inclusive; observations in the future reject.
Stale or incomplete input rejects all new attempts, including integration/repair,
until the observation owner refreshes it. Restart never refreshes old timestamps.

New writers reject on unresolved integration regression, then two active writers,
then two distinct delivered/unintegrated artifacts, in that precedence order.
Artifact identity is the pair `{repository, artifact_id}`; duplicate reports count
once. The delivery-state owner must retain awaiting-merge and integrating artifacts
until confirmed integration or explicit withdrawal. This policy does not poll PRs,
cancel existing writers, or infer a delivery is integrated from its status label.

Integration and explicitly assigned regression-repair roles bypass writer counts
and delivery backpressure. Repair additionally requires an observed regression.
Role authorization and repair scope come from the trusted coordinator, never a
model or ticket-controlled string. This policy is not authorization or an acquired
slot: STA-201 must atomically enforce a single integration owner and reservation,
and STA-193 owns issue fencing. An existing integration owner is evidence for that
boundary; this pure policy does not evict it or grant concurrent integration.

No production orchestrator uses this module until the final wiring is accepted.
Focused tests cover admission only, not actual queue races, native hosts or leases.
Run `mix test test/symphony_elixir/dispatch_capacity_test.exs`, then the original
full `make all` gate. STA-204 owns combined scheduler/restart race qualification.
