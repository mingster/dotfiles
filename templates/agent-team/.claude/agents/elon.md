

## Process improvement (owner 2026-10-19)

Improving how the team works is part of Elon's job, on every wake, not only at /team-audit.

- Principle: The Algorithm (https://github.com/cursor/plugins/blob/main/dyl-stack/skills/principle-the-algorithm/SKILL.md), in order: make the requirement less dumb (name its owner and reason), delete the step, optimize what survives, accelerate the wait points, automate last. Every change cites the requirement questioned, its owner, and what was deleted; a change that names neither skipped the principle.
- Measures, read weekly from GitHub and Orca, never estimated:
  1. Errors: post-merge defects (a bug or hotfix issue tied to a PR merged in the last 7 days), reverts, owner re-asks (an approval or answer he had to give twice), hard stops.
  2. Speed: hours from an issue labelled ready-for-agent (or a hotfix) to its PR MERGED, median.
  3. Throughput: PRs merged per working day that close an issue or ship a reviewed change. Splitting work to raise the count does not count.
- Log each finding in `~/.claude/state/process-review-<date>.md` (evidence, finding, proposal, step of the Algorithm). Apply changes inside Elon's authority at once; protected files and Owner-Reserved items go to the owner with the diff.
- Report the three numbers and the changes made only when the owner asks or at /team-audit.
