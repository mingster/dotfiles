---
name: grill-backlog
description: Backlog sweep on top of the grilling skill. Grill the owner on every issue that waits on a human (labels ready-for-human, needs-triage) until each one is agent ready, then record the answers on the issues, relabel them ready-for-agent and dispatch. Use with /grill-backlog, "grill me on all", or when the queue has only owner blocked issues left.
---

# Grill the backlog

Run by Elon. Goal: turn issues that wait on the owner into issues an agent can finish, by asking the owner only what only he can answer.

## 1. Collect

From the repo root, using the tracker in `docs/agents/issue-tracker.md`:

```bash
for l in ready-for-human needs-triage; do gh issue list --label $l --limit 50 --json number,title --jq '.[]|"\(.number) \(.title)"'; done
```

Use the `triage` skill for issues that still need evaluation or claim verification: read `~/.agents/skills/triage/SKILL.md` and follow it. For the owner decision sweep, read the remaining issues and their prior decisions.

## 2. Sort each issue

| Kind | What it needs | What you do |
|---|---|---|
| Fact the repo or a read only query answers | nothing from the owner | look it up yourself, or have an agent do it; never ask |
| Production change by procedure (cron line, env flag, SQL file, restart) | owner's approval, not his hands | offer option A: release-manager does it at the next release under the owner's approval |
| Product, scope or trade off decision | the owner's call | ask, with your recommendation |
| Physical or credential action only the owner can do (a host config, a vendor account) | his hands | give the exact commands, paste ready, no placeholders such as `<name>` that a shell cannot parse |
| Needs research first (growth, pricing) | a study | offer option A: the right role studies read only data and returns 2 or 3 proposals |

Most "ready-for-human" issues turn out to be the second kind. Converting them is the main win.

## 3. Ask in rounds

Use the `grilling` skill for the interview and its "Grilling on tracker issues" rules for recording decisions and changing labels. This skill adds only the backlog rules:

- Each question answerable with a letter; A is your recommendation, with one line of why and the cost of B. End with "all A is fine".
- Never quote secrets you find while reading (keys, passwords in scripts). Report them as a finding with the fix.

## 4. Queue the resolved work

Use the `crew` skill to deliver resolved issues under the usage gate. Production steps join the next release batch through `deploy`; the release still needs the owner's explicit go. New facts that affect a spec go on its issue. New problems follow `docs/agents/issue-budget.md`.

## Done when

No issue is left in ready-for-human or needs-triage except those waiting on a physical owner action that is named, with its exact command, on the issue.
