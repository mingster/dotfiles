---
name: team-audit
description: Audit agent roles, team skills, model-routing.md and team docs when the owner says "team-audit". Find evidenced problems, give each one fix, and report the delivery and Orca stage metrics.
---

# Team audit

Orca runs the script and the metrics weekly and reports one line; that run fixes nothing. The full audit runs only on the owner's word, by architect-pm. Edits only on a branch in your own worktree; Elon publishes and merges it.

## 1. Deterministic checks

Run `ROLE_RECEIPT_BASE="<head shas of the previous audit>" ~/dotfiles/script/team-audit.sh --report` (default projects come from the untracked `script/team-audit.local.conf`, one root per line; pass project roots to override). The six checks are sync, budget, wording, skills, labels and receipt. Each `FINDING <check>` line names the file. Fix every finding or explain why it is a false positive (a line may opt out with the comment `team-audit: allow`). For a `sync` finding, run `~/dotfiles/script/agent-team.sh check <project>` to read the drift, then run `~/dotfiles/script/agent-team.sh sync <project>` to remove a Tier 2 skill copy from the project; edit the skill only in the dotfiles source. A `labels` finding is a `ready-for-agent` issue that also carries a label saying it is not ready: remove one of the two. A `WARN labels` line means the gh call failed; it is a gap, not a clean record. A `receipt` finding is a role-file commit without its `Owner-approved:` trailer: report its diff to Elon for the owner's approval. Never run `skills update`.

## 2. Evidenced problems

Find the last audit date from the previous `team-audit` PR. Read only what changed since then (`git log --since <date> -- .claude .agents docs/agents`) and the private observation log `~/agent-state/team-observations.tsv` (written by `team-audit.sh --log`), which holds only observations that would change a rule. A source you cannot read is a gap to report, never a clean record. Never copy it into a repository or `~/.claude/notes`, which is public.

Report a problem only with evidence, and give it one structural fix (a lint, check, script or rule). Use the `writing-for-agents` skill for wording, and the `retro` skill for a failure tied to one session. Name both file lines when rules disagree: owner rules and `~/dotfiles/templates/agent-team/docs/agents/team.md` win, then `.claude/model-routing.md`, then the role file; Orca's `orchestration` skill owns worker lifecycle. No per role write-ups. Once the report is published, set each used row's fix ticket and status.

Team rules and scripts must not grow in total lines; a safety fix may, with the reason stated.

## 3. Metrics

`--report` runs `bun script/team-audit-metrics.ts --repo <owner/name>` per project (two gh calls each); stdout is one `key=value` line per metric (`n=` sample counts on rates and medians; month counts are plain integers). Missing data reads unknown, never zero.

Delivery: `median_ticket_start_to_merge_minutes` (starts when the closing issue received `ready-for-agent`, or unknown for that PR), `first_pass_checks_fail_rate`, `p0_filed_this_month`, `p1_filed_this_month`, and `reopened_or_hotfix_rate`.

Orca stages, per merged PR, from the dispatch log `~/agent-state/team-dispatches.tsv` (`issue`, `dispatched_at`): queue is ready-for-agent to dispatch, build is dispatch to the first Checks result, merge is that result to merge. Each stage reports median, p75, max, samples and fully verified samples. Fleet per host: `heavy_gate_median_wait_minutes_<host>` and `worktrees_over_limit_<host>` (`worktrees_over_limit_<host>` reads unknown until a fixed host list exists).

## 4. Output

The last line of `--report` is `ROLE_RECEIPT_BASE="<head shas>"`. Record it in the report so the next audit passes it to `team-audit.sh --report`. A `worker_done` to Elon with the script result, each problem with its file, line, fix and verification or approval gate, the metrics, and the line count change. Make agreed edits on `mingster/team-audit-<date>` in the dotfiles template and each project, keep `team-audit.sh` clean and `agent-team.sh check` passing.
