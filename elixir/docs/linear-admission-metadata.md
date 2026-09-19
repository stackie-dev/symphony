# Complete Linear admission observations

`Linear.AdmissionMetadata.fetch(issue, organisation, route, reader)` produces the
version-one `Dispatch.Snapshot` or a redacted error atom. The caller supplies the
existing `Linear.Client.graphql/2` transport; tests supply contract-shaped replies.
The organisation and intended route come from trusted coordinator configuration.

The reader fetches fresh core issue fields and paginates labels, children and
incoming relations separately, with 100 records per page and at most 100 pages
per connection. Missing pagination metadata, repeated cursors, exhausted bounds,
transport errors, GraphQL errors (including partial successes), malformed nodes
and a mismatched issue identity fail closed. Error values never contain response
body text. Identical duplicate observations are deduplicated; conflicting blocker
states are rejected rather than choosing an apparently completed state.

Only incoming `blocks` relations become prerequisites. Other relation types are
not dependencies. The original normalized issue's description, branch, URL and
other unrelated fields are preserved, including imported GitHub context. An
observed null project or assignee is represented as null; an unread/malformed
field is an error. The complete flag is set only after every required connection
and node has been processed. Eligibility still rejects invalid routing or an
unassigned issue; this reader does not decide whether work may run.

Linear does not expose an atomic transaction spanning these reads. The timestamp
records the start of observation, so slow pagination cannot make old core state
appear fresh. An optional fifth argument supplies the clock for deterministic
tests. The timestamp is not a guarantee of snapshot isolation. The
final dispatch owner must refresh before launch, enforce freshness and reconcile
subsequent revocation. This preparatory module is not wired into dispatch yet.

Run `mix test test/symphony_elixir/linear_admission_metadata_test.exs` and the
unchanged `make all` gate from `elixir/`. Tests cover pagination boundaries,
identity mismatch, incomplete evidence, duplicate/conflicting observations and
preservation of existing issue context. Real transport composition is verified
by the later dispatch integration owner.
