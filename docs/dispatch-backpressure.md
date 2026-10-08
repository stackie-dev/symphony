# Durable dispatch admission (STA-201)

`Admission` owns the filesystem-serialized reservation journal. `Launch` composes
that authority with the canonical STA-200 delivery reader before the orchestrator
starts a new writer. Accepted `Capacity.check/3` remains the admission policy.

Two writer reservations are allowed. Idle continuation/retry reservations still
count; a verified retry reuses its token and receives a fresh session capability.
At two distinct delivered-but-unintegrated PR identities, a new writer is held.
Every new writer refreshes the canonical reader; missing, stale, incomplete,
conflicting or unavailable observations never fall back to an older saved count.
Actual dispatched issue IDs join configured selection and a durable remembered
issue list. Terminal release and restart do not erase these identities. The
reader independently retains known PRs until confirmed merge or withdrawal.

Integration and repair share one exclusive durable owner. They can proceed during
writer backlog or delivery-read failure, subject to existing scheduler/host limits.
Only trusted workflow issue-to-scope mappings select those roles. Ticket labels,
descriptions and agent output cannot grant them. Repair additionally requires a
matching durable regression scope and cannot create an unlimited third writer
class. Regression blocks new writers even with an empty backlog. `repaired/4`
requires the exact current owner's token/session and matching regression/scope,
completed successful validation, a tested revision and a retained receipt. These
receipts are supplied by trusted integration control; this API does not execute
or independently attest a test run. Reporting ticket completion is insufficient.

## Workflow configuration

```yaml
dispatch:
  repositories: [owner/repository]
  issue_ids: [native-linear-issue-id]
  state_dir: .symphony-dispatch
  max_age_ms: 60000
  integration_scopes:
    native-integration-issue-id: core
  repair_scopes:
    native-repair-issue-id: core
```

Repository allowlists and selected issue IDs must be explicit. An empty selected
list is permitted; actual launch identities and prior remembered identities still
join selection. Missing or invalid configuration holds new dispatch. Relative
paths resolve beside WORKFLOW. Dispatch configuration is captured at orchestrator
startup: reload cannot switch authority while agents are in flight. Preserve the
same absolute authority path across restarts; moving/deleting authority is an
operator migration, never a way to clear capacity. Trusted embedding callers may
inject reader callbacks through `:dispatch_reader_options` application configuration
or explicit orchestrator `:dispatch_config` start options; defaults use real
canonical clients. Injection changes the read boundary, not reservation policy.

The journal uses private permissions, exclusive directory creation for a
cross-process transaction lock, synced temporary bytes and atomic rename. The
reader JSON is a sibling `state_dir-deliveries.json`; neither initialization nor
reader directory creation can masquerade as a missing journal. A corrupt or
missing existing journal fails closed. There is no lease timeout or PID takeover.
This boundary assumes a local filesystem with atomic mkdir/rename semantics and
persistent storage; it does not claim distributed/network-filesystem consensus
or power-loss directory-fsync guarantees.

## Stop, restart and recovery

An observed task `DOWN` or rejected spawn marks the exact session idle. Continuation
retains its slot. Terminal reconciliation releases only an idle matching handle.
Forced/uncertain shutdown can retain an in-flight reservation even after the local
running entry disappears. After restart the journal retains counts and ownership;
new processes do not guess whether old remote sessions stopped.

Status includes writer count, integration owner, regression and per-issue
`in_flight_or_recovery_required` / `retry_reserved` holds, plus exact launch errors.
It never publishes tokens. The private journal's token/session is a capability.
An authorized operator must verify that exact remote session stopped, retain a
receipt, then call `Orchestrator.recover_dispatch/4` with the matching handle and
`%{authority: :trusted_operator, stopped: true, session: handle.session, receipt: ...}`.
Wrong token/session, missing receipt and locally running tasks reject recovery.
Recovery attaches the existing idle reservation; it neither starts an agent nor
clears regression. Release or normal scheduler retry can then proceed. An abandoned
transaction lock likewise requires operators to verify all authority users stopped
before repairing storage offline; no automatic lock deletion is provided.

## Root validation (not run by the source worker)

From `elixir`, after composing STA-200 and STA-201, run the new
`dispatch_integration_backpressure_test.exs`, both `dispatch_backpressure/*_test.exs`,
original `core_test.exs`, `orchestrator_status_test.exs`, and the STA-200 reader suite
in one completed `mix test` invocation. Independent OS-process contention is part
of the owner test. Existing assertions are preserved. Source parser/formatter
checks do not establish runtime correctness or protected delivery.
