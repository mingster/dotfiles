---
name: team-audit
description: Audit agent roles, team skills, model-routing.md and team docs when the owner says "team-audit". Find mistake classes with workflow-from-chats, fix each with /correct, and report the delivery and Orca stage metrics.
---

# Team audit

Orca runs the script and the metrics weekly and reports one line; that run fixes nothing. The full audit runs only on the owner's word, by architect-pm. Edits only on a branch in your own worktree; Elon publishes and merges it.

## 1. Deterministic checks

Run `ROLE_RECEIPT_BASE="<head shas of the previous audit>" ~/dotfiles/script/team-audit.sh --report` (default projects come from the untracked `script/team-audit.local.conf`, one root per line; pass project roots to override). Each `FINDING <check>` line names the file; the script's header says what each check means and the report gives the recommended fix. A `WARN` line is a gap, not a clean record. Never run `skills update`.

## 2. Find

Start one supervised Orca worker through `~/dotfiles/script/heavy-gate.sh` that runs `workflow-from-chats` over the last 7 days of transcripts, plus the observation log `~/agent-state/team-observations.tsv` (written by `team-audit.sh --log`). A mistake class counts after two hits or one strong confidence hit. Never copy transcripts or the log into a repository or `~/.claude/notes`, which is public.

## 3. Fix

Hand each class to `/correct`. It picks the level and proves the check fails on a real past mistake. A change to the rule table in `~/dotfiles/templates/agent-team/docs/agents/team.md` goes to Elon as a draft on a branch with no `Owner-approved:` trailer. Once the report is published, set each used log row's fix ticket and status.

## 4. Metrics

`--report` runs `bun script/team-audit-metrics.ts --repo <owner/name>` per project (two gh calls each); stdout is one `key=value` line per metric (`n=` sample counts on rates and medians; month counts are plain integers). Missing data reads unknown, never zero.

Delivery: `median_ticket_start_to_merge_minutes` (starts when the closing issue received `ready-for-agent`, or unknown for that PR), `first_pass_checks_fail_rate`, `p0_filed_this_month`, `p1_filed_this_month`, and `reopened_or_hotfix_rate`.

Orca stages, per merged PR, from the dispatch log `~/agent-state/team-dispatches.tsv` (`issue`, `dispatched_at`): queue is ready-for-agent to dispatch, build is dispatch to the first Checks result, merge is that result to merge. Each stage reports median, p75, max, samples and fully verified samples. Fleet per host: `heavy_gate_median_wait_minutes_<host>` and `worktrees_over_limit_<host>` (`worktrees_over_limit_<host>` reads unknown until a fixed host list exists).

## 5. Output

Check the report for customer data before posting; remove it. The last line of `--report` is `ROLE_RECEIPT_BASE="<head shas>"`. Record it in the report so the next audit passes it to `team-audit.sh --report`. A `worker_done` to Elon with the script result, each class with its `/correct` fix and proof, the metrics, and the known gap: only the coordinator host's transcripts are read. Make agreed edits on `mingster/team-audit-<date>` in the dotfiles template and each project, keep `team-audit.sh` clean and `agent-team.sh check` passing.
