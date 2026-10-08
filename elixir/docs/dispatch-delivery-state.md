# Durable delivery observations

`SymphonyElixir.Dispatch.DeliveryState` is the canonical reader for delivery
backpressure. It does not reserve writers, acquire integration ownership, change
tracker state or merge PRs. Admission consumes a successful fresh observation,
then applies the existing dispatch capacity contract.

Call `refresh(path, options)` before a new admission. Required options are
`issue_ids` (explicit selected native Linear IDs, including terminal tickets when
needed) and `repositories` (repository allowlist). An explicit empty issue list
is valid and still confirms previously known deliveries. `now_ms` defaults to
Unix milliseconds; `max_age_ms` defaults to 60,000. `read(path, now_ms, max_age_ms)`
reloads persisted observations after restart and rejects stale/future data. It
must not turn a failed refresh into permission to launch a writer.

Both operations return `{:ok, %DeliveryState.Snapshot{version: 1, complete: true,
observed_at_ms: ..., deliveries: [{repository, native_pr_number}], sources: ...}}`
or `{:error, {:delivery_state, reason}}`. Reasons include `missing`, `corrupt`,
`stale`, `future`, `incomplete_tracker`, `incomplete_artifact`, `stale_source`,
`conflicting_source`, `persistence`, `invalid_options` and `unavailable`. Failures
are uncertainty, never an empty backlog. Do not expose internal failure payloads
or credentials in public status output.

The real adapter reads selected Linear issue descriptions, attachments and all
comment pages through the existing GraphQL client. Every page must have the same
native issue identity, revision and description. Cycles, missing cursors, errors,
malformed nodes or a 100-page limit fail closed. It recognizes linked GitHub PR
URLs and normalizes repository case and native PR numbers. References outside
the allowlist do not enroll unrelated work. No repository-wide PR enumeration
or comment-derived completion inference occurs. Generic non-PR artifacts need
an authoritative read adapter before they can enter this PR-backed reader; an
arbitrary evidence/comment hash is not an integration identity.

The existing GitHub client performs only `GET /repos/{repo}/pulls/{number}` for
linked or durably known PRs. Open non-draft PRs count while queued, in review,
waiting for CI, integrating or awaiting protected merge. New unfinished drafts
do not count. A previously counted PR stays outstanding if changed back to draft
or its tracker link disappears. Only a newer native confirmed merge or native
closed-unmerged withdrawal clears it. A newer reopened/revised PR counts again.
Equal conflicting or older source revisions reject the entire refresh. Tracker
Done alone never removes a delivery. Known tombstones retain revision ordering
across restarts, and selected issues cannot silently shrink known work.

The JSON store is replaced atomically after a same-directory exclusive temporary
file is written, synced and closed. Failure retains the previous canonical file;
missing/corrupt canonical data is never silently reset. Temporary files are not
recovery inputs. Refreshes for the same expanded path serialize in one connected
BEAM runtime using a lock, not a dispatch lease. Separate disconnected runtimes
must not write the same store. File sync plus atomic rename gives restart
recovery; full power-loss durability depends on filesystem directory-sync
semantics and is not claimed here. The integrating runtime owns a private store
path with trusted parent directories; this is not an untrusted path API.

Tests may supply `tracker_read(query, variables)` and `pr_read(repo, number)`
contract collaborators. `github_options` forwards existing GitHub client options
for a real client/request-boundary test with redacted settings; production uses
its existing configured client. No new credentials, dependencies or queues are
introduced. Existing contract, eligibility and capacity modules are unchanged.

Root qualification (not run by source workers):

```sh
cd elixir
mix format --check-formatted
mix specs.check
mix test test/symphony_elixir/dispatch_delivery_state_test.exs test/symphony_elixir/delivery_state test/symphony_elixir/dispatch_contract_test.exs test/symphony_elixir/dispatch_capacity_test.exs test/symphony_elixir/linear_admission_metadata_test.exs test/symphony_elixir/github_adapter_test.exs test/symphony_elixir/core_test.exs
```

STA-201 supplies configuration, startup, dispatch revalidation and status wiring.
A source handoff or a recovered file is not a behavioral qualification result.
