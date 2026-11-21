---
name: grill-backlog
description: Owner entry for issues that wait on a human. List the issues labeled ready-for-human or needs-triage and ask the owner about them one at a time. Use with /grill-backlog or "grill me on all".
---

# Grill the backlog

Run by the coordinator. List the issues that wait on the user, using the tracker in `docs/agents/issue-tracker.md`:

```bash
for l in ready-for-human needs-triage; do gh issue list --label $l --limit 50 --json number,title --jq '.[]|"\(.number) \(.title)"'; done
```

Before any question about an issue, run `~/dotfiles/script/owner-decisions.sh <owner/repo> <issue>`. Exit 0 means the owner already decided it (the decision is printed): apply it, never ask again. Exit 2 means the check failed, so do not ask until it runs. Look up yourself anything the repo or a read only query answers. Then ask the owner about the rest one issue at a time with the `grilling` skill, which also records each answer and changes the label. Each question is answerable with a letter: A is your recommendation, with one line of why and the cost of B.

Never quote secrets you find while reading; report them as a finding with the fix. Resolved issues go to Orchestrate (`/elon`).
