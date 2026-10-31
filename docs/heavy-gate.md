# Heavy-gate cleanup and retained capacity

The gate keeps every claimed slot until complete process inspection proves its
registered groups contain no live members. Failed or malformed inspection, an
unpublished ledger, and a failed quarantine rename retain capacity. A completed
command's exit status is preserved; diagnostics describe any retained group.

Cleanup signals require a live group snapshot and an unreaped direct-child
leader verified using `waitid(WNOWAIT)` before each signal. The unreaped leader
reserves the numeric PID through signalling. Cleanup never signals a saved PGID
after its leader has been reaped, or when identity or inspection is unknown.
Platforms without this inspection primitive withhold signals and retain capacity.

Nested gate commands stay in their ancestor's registered process group rather
than creating independent sessions. A nested command surviving its parent keeps
that group's capacity occupied. Commands that deliberately escape the group with
their own session-management code are outside this cooperative gate's contract.
Nested timeout returns 124; the ancestor owns group cleanup and capacity.

Nested admission requires an owner-held kernel lock as well as the token and
running markers. Cleanup closes this lock before attempting filesystem
quarantine. A failed rename cannot leave the old token authorized. Older slots
without kernel authorization cannot authorize nesting; wait for those jobs to
finish before mixing helper versions in a nested invocation.

## Inspect-only recovery

Inspect the retained slot files under `~/.cache/heavy-gate/slot-*`: `pid`,
`groups`, `groups-ready`, `running`, and `quarantine`. Record their contents and
capture a complete `ps -axo pgid=,pid=,ppid=,uid=,stat=,comm=` snapshot for review.
Do not infer process identity from a numeric PID or PGID, a stale token, or a
missing process row in an unsuccessful inspection.

Recovery is inspection only: do not signal recorded numbers, delete slot files,
or fabricate a ready ledger. Once the owner exits, normal admission can reclaim
a published ledger only after successful inspection proves all registered groups
empty or zombie-only. Unknown or unpublished ledgers remain held for operator
review; this document grants no manual capacity-release authority.
