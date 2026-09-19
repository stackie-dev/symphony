# Linear eligibility policy

`SymphonyElixir.Dispatch.Eligibility.check(snapshot, policy)` is a pure decision
over the version-one dispatch observation contract. Policy has `repositories`
(nonempty known repository names) and `route` (the intended Symphony label).

The result is `:ok` or `{:reject, reasons}`. Reasons have stable order: inactive,
aggregate, escalated, prerequisites, repository, route, assignment. Invalid policy
and incomplete/invalid observation evidence return their own single reason before
business rules run. Both Todo and In Progress require every blocker to be Done;
Canceled and Duplicate do not prove delivery. Native Linear tickets need no
GitHub source. Labels and states use the same exact spelling as operator preflight.

Repository and route projections must agree with actual labels, preventing a
caller from selecting one of several labels and hiding ambiguity. Project and
assignee must be present. The adapter must declare observations incomplete when
either was not read, as distinct from observing an unassigned issue.

This module owns eligibility only. It neither performs I/O nor reserves capacity,
chooses a platform, judges observation age, acquires an exclusive lease or starts
an agent. The orchestrator is not wired to this policy yet. A later wiring change
must refresh complete metadata immediately before every initial/retry/resume
attempt, then enforce placement, capacity and ownership before side effects.

`test/fixtures/dispatch_admission_v1.json` is the canonical shared eligibility
fixture. The ExUnit policy test consumes it. Parent's `readiness` function can
consume each `{...base, ...case.patch}` with the fixture's `policy`; `ready` must
match. Platform selection and explicit pre-label operator mode are outside this
fixture's shared surface and retain their own tests. Parent integration must run
this comparison after pinning the accepted Symphony commit, not copy the policy.

From `elixir/`, run `mix test test/symphony_elixir/dispatch_eligibility_test.exs`,
then the unchanged repository `make all` gate. Passing this suite alone does not
establish scheduler enforcement or authorize queue admission.
