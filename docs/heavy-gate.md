# Heavy gate

**Heavy jobs** are Playwright (any playwright test or e2e run) and a production
build (`bun run build`, `next build`). They run through `heavy-gate.sh
--weight 2` and wait on host slots, 1 minute load and free memory.

**Measure mode** (`--measure`) is for full project type checks during a one week
owner trial. It never waits for a slot; it logs wall time, 1 minute load and
free memory percent per run to `~/.orca/logs/heavy-gate-measure.log`.

Unit tests, lint and review scripts are not heavy and do not use the gate.
`head-checks.sh` wraps only Playwright and build checklist steps; the type
check step uses measure mode.

Slot waits still log `stamp host=H wait_s=S` lines to
`~/.orca/logs/heavy-gate-wait.log` for `fleet-watch.py` and team audit metrics.

## Cleanup and retained capacity

The gate keeps every claimed slot until complete process inspection proves its
registered groups contain no live members. Failed or malformed inspection retains
capacity. A failed quarantine rename during live cleanup withholds signals and
keeps capacity until the owning gate exits. Once the owner is gone, a slot
reclaims when its recorded groups are proved empty or zombie only, unless both
`running` and `quarantine` markers remain from interrupted cleanup. A completed
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

## Gate death before publication

The command is started behind a small launcher that waits until the gate has
published the command's process group. Only then is the command released. A slot
carries a `prelaunch` marker until that point. If the gate dies first, the
command never ran, so once the owner pid is gone the slot is reclaimed
automatically. A slot without `prelaunch` follows the rules above: once the owner
is gone it reclaims when its recorded groups are proved empty or zombie only,
unless both `running` and `quarantine` markers are present. A lone `running`
marker after the owner exits does not block that reclaim. A slot with no such
proof stays held, and the wait notice names it.

## Inspect-only recovery

Inspect the retained slot files under `~/.cache/heavy-gate/slot-*`: `pid`,
`groups`, `groups-ready`, `running`, and `quarantine`. Record their contents and
capture a complete `ps -axo pgid=,pid=,ppid=,uid=,stat=,comm=` snapshot for review.
Do not infer process identity from a numeric PID or PGID, a stale token, or a
missing process row in an unsuccessful inspection.

Recovery is inspection only: do not signal recorded numbers, delete slot files,
or fabricate a ready ledger. Once the owner exits, normal admission can reclaim
a published ledger after successful inspection proves all registered groups
empty or zombie only, including when only a `quarantine` marker remains.
Inspection must succeed and `groups-ready` must be present. Slots held because
groups are still live, the ledger is malformed, `groups-ready` is missing, or
both `running` and `quarantine` are present remain for operator review; this
document grants no manual capacity release authority.

## Fair turns for larger jobs

A job that cannot get its slots publishes a waiter record under
`~/.cache/heavy-gate/waiting/`. Once a waiter has waited
`HEAVY_GATE_MAX_WAIT_SECONDS` (default 300), jobs that need fewer slots than it
stop taking slots until it has run.

Before that bound passes, lighter jobs run as usual. Only waits for slots count,
not waits on the load or free memory checks. Records of dead owners are ignored.
The slot limit is never exceeded, since every claim still goes through the same
atomic check.
