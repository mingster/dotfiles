# Fleet watch is a monitor and a separate dispatcher

Status: Proposed  
Date: 2026-11-13

Fleet watch was one pass every 5 minutes that monitored the fleet, started verifiers, rework and new issues, restarted stalled workers, opened issues and mailed the coordinator. A slow or failing dispatch step delayed or killed the whole pass, and since notices went out last, a killed pass told nobody. From 10 to 13 Nov no notice reached the coordinator at all, and nothing showed it. The owner decided the shape on [#986](https://github.com/mingster/dotfiles/issues/986) (all eight grill recommendations accepted). The full design is [fleet-watch-design.md](../agents/fleet-watch-design.md).

## Decision

1. **Two jobs.** A monitor every 5 minutes that only reads and sends notices, and a dispatcher every 2 minutes that only starts and restarts workers. Separate automations, state files and time limits. The dispatcher hands its notices to the monitor through an outbox file and never mails itself.
2. **Fleet watch has its own sender identity in Orca** and mails the Run, not a terminal. After 3 failed sends in a row it opens one GitHub issue in the private `agent-state` repo.
3. **One try per key, then park.** A failed start is not retried until what it acts on changes (a new push, an issue edit, a config change). Gate refusals are not failures.
4. **Ownership.** The dispatcher restarts only workers it started. Every other worker is the coordinator's, and fleet watch only reports it.

## Consequences

The state is split in two and the old single state file is retired, so going back to one pass means merging state by hand. That is why this is an ADR. The monitor's mail no longer waits on the dispatcher, and the verifier path no longer waits on monitoring, which is what makes the 5 minute target from green checks to a started verifier reachable. A failed start now stays failed until something changes, so a transient Orca error costs one notice and a manual re-arm instead of hours of retries. The coordinator, not fleet watch, owns recovery for the workers it dispatched, so the two stall recovery paths stop overlapping. Two automations must be installed and kept enabled together; the monitor reports a dispatcher that has not run for 10 minutes.
