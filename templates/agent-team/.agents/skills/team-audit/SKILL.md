---
name: team-audit
description: Audit agent roles, team skills, model-routing.md and team docs when the owner says "team-audit". Find evidenced problems, give each one fix, and report the delivery and Orca stage metrics.
---

# Team audit

Orca runs the script and the metrics weekly and reports one line; that run fixes nothing. The full audit runs only on the owner's word, by architect-pm. Edits only on a branch in your own worktree; Elon publishes and merges it.

## 1. Deterministic checks

Run `ROLE_RECEIPT_SINCE=<previous audit date> ~/dotfiles/script/team-audit.sh` (default projects come from the untracked `script/team-audit.local.conf`, one root per line; pass project roots to override); a project that maintains keep and delete tool lists in spec and intent sets `TEAM_AUDIT_TOOL_LISTS=<spec-path>:<intent-path>` for that run. Each `FINDING <check>` line names the file. Fix every finding or explain why it is a false positive (a line may opt out with the comment `team-audit: allow`). For a `sync` finding, edit the dotfiles source and run `~/dotfiles/script/sync-team-skills.sh <project>`; never edit a generated copy. For an `mp-upstream` finding, run `~/dotfiles/script/sync-mattpocock-skills.sh`, review `git diff` of `.agents/skills`, and commit it on the audit branch in dotfiles. A `WARN mp-upstream` line means the network check was skipped; rerun later. A `receipt` finding is a role-file commit without its `Owner-approved:` trailer: report its diff to Elon for the owner's approval. Never run `skills update`.

## 2. Evidenced problems

Find the last audit date from the previous `team-audit` PR. Read only what changed since then (`git log --since <date> -- .claude .agents docs/agents`) and the private log `~/.claude/state/team-observations.md`, which holds only observations that would change a rule. A source you cannot read is a gap to report, never a clean record. Never copy it into a repository or `~/.claude/notes`, which is public.

Report a problem only with evidence, and give it one structural fix (a lint, check, script or rule). Use the `writing-for-agents` skill for wording, and the `retro` skill for a failure tied to one session. Name both file lines when rules disagree: owner rules and `~/dotfiles/templates/agent-team/docs/agents/team.md` win, then `.claude/model-routing.md`, then the role file; Orca's `orchestration` skill owns worker lifecycle. No per role write-ups. Once the report is published, delete each observation line you used.

Team rules and scripts must not grow in total lines; a safety fix may, with the reason stated.

## 3. Metrics

Run `bun bin/team-audit-metrics.ts`; stdout is one `key=value` line per metric (`n=` sample counts on rates and medians; month counts are plain integers). Missing data reads unknown, never zero.

Delivery: `median_ticket_start_to_merge_minutes` (starts when the closing issue received `ready-for-agent`, or unknown for that PR), `first_pass_checks_fail_rate`, `p0_filed_this_month`, `p1_filed_this_month`, and `reopened_or_hotfix_rate`.

Orca stages: `median_stage_queue_minutes`, `median_stage_build_minutes`, and `median_stage_merge_minutes`. Fleet per host: `heavy_gate_median_wait_minutes_<host>` and `worktrees_over_limit_<host>` (`worktrees_over_limit_<host>` reads unknown until a fixed host list exists).

## 4. Output

A `worker_done` to Elon with the script result, each problem with its file, line, fix and verification or approval gate, the metrics, and the line count change. Make agreed edits on `mingster/team-audit-<date>` in the dotfiles template and each project, keep `team-audit.sh` clean and `sync-team-skills.sh --check` passing.
