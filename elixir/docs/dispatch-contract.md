# Dispatch observation contract, version 1

This contract is preparatory. The current orchestrator does not consume it yet.
Structural validation does not establish eligibility, freshness, placement,
capacity or lease ownership, and must never be used alone to launch an agent.

`Dispatch.Contract.validate(snapshot, worker, attempt)` returns
`{:ok, %{snapshot: snapshot, worker: worker, attempt: attempt}}`, or
`{:error, {:incomplete | :invalid, :snapshot | :worker | :attempt}}`.
The first failing observation wins in snapshot/worker/attempt order.
Incomplete means necessary evidence is absent; invalid means a value is malformed
or its schema version is unsupported. Neither is an empty successful observation.

The types live in `lib/symphony_elixir/dispatch/observations.ex`:

- `Snapshot` wraps the existing `Tracker.Issue`; it does not copy its state,
  labels or blocker list into a competing representation. Scope is the trusted
  tracker and organisation/team identity. `canonical_issue_id` is the provider's
  underlying ticket identity, resolved by the adapter from native references;
  `Issue.id` can instead identify a board entry and must not be used as the fence.
  Missing native identity is incomplete evidence. `child_ids`, repository and intended
  route are explicit. The tracker adapter may set `complete: true` only after all
  admission-relevant pages succeed. Nil relation data is never an empty list.
- `Worker` has an explicit configured host identity, OS, availability and slots.
  `:unknown`, offline and zero capacity are structurally valid observations but
  are not usable placements. A hostname is not OS evidence.
- `Attempt` carries writer/integration/repair role, active writers, canonical
  delivered artifact identities `{repository, artifact_id}`, integration owner,
  integration-regression state and optional preferred resume host. Duplicate
  delivery observations must be deduplicated by the accounting owner. This is
  evidence, not a reservation or acquired lease.

All observation times are Unix milliseconds. Structural validation checks their
shape, not their age. Consumers use an explicit clock and configured freshness
policy; persisted observations never inherit freshness on restart. Unknown
versions are rejected. Future changes have one contract owner and require updated
conformance tests and a consumer compatibility assessment.

## Ownership and final dispatch order

`Contract.identity/1` on a validated snapshot returns
`{tracker, organisation_or_team, issue_id}`. Never include route, host alias or
workspace spelling in the exclusive issue identity. An attempt/lease token is a
separate opaque value and must not be equated with the issue ID.

The final orchestrator dispatch boundary owns this order, for initial attempts,
retries and explicit resumption:

1. Refresh complete tracker evidence and validate its structure.
2. Check eligibility against the existing active-state/leaf/prerequisite policy.
3. Select a compatible available worker, preserving existing-checkout affinity,
   and evaluate the role-specific capacity policy.
4. Atomically acquire the canonical issue fence and relevant writer/integration
   ownership. Revalidate after any asynchronous wait or observation change. On
   failure, release only the caller's acquired ownership; do not launch.
5. Only then create/resume the checkout and start the agent. Hold the lease through
   the attempt and preserve partial work on escalation or uncertain recovery.

No validation, selection or failed acquisition may create a checkout or start an
agent. A local process lock is insufficient proof of cross-host exclusivity;
unsupported overlapping coordination scopes must fail closed. External tracker
changes cannot be made atomic with local spawn: the final fresh check bounds that
race, and running-work reconciliation must still honor later revocation.

Eligibility owns tracker policy; placement owns platform/host selection; capacity
owns admission counts and integration backpressure; fencing owns exclusive lease
lifecycle. None duplicates another's policy. Each provider develops against these
fixtures; the wiring owner must test their actual combined implementations.

## Validation

Run `mix test test/symphony_elixir/dispatch_contract_test.exs` plus the original
`core_test.exs` and `orchestrator_status_test.exs` from `elixir/`. The contract suite
proves structural behavior only. It deliberately accepts structurally complete
Backlog, old, offline, unknown-platform and capacity-exhausted observations to
prevent schema validation from silently becoming an incomplete admission policy.
