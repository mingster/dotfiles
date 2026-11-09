# PR owner self-review (plain-text checklist)

Run this on every push path before `worker_done` or before opening a PR. No subagents or IDE-only tools are required; Claude may use the full `code-review` skill instead.

1. `git diff origin/main...HEAD` (or the brief's base) and read every changed file.
2. Check each change against the issue evidence and predicate and `AGENTS.md` / repo standards.
3. For any doc you changed, run `bash ~/dotfiles/script/doc-fact-check.sh --repo . --base origin/main --head HEAD -- <files>` and explain every flagged line (reworded, moved, or deliberate removal).
4. Fix or explain every finding.
5. Put a `## Self-review` section in the PR body (or in `worker_done` when the brief is local-only) naming the **exact head sha** you reviewed and one line per finding with its outcome.

Cursor and Antigravity workers run this checklist as written. It is enforced again at merge: `script/ship.sh` and `script/lead-merge.sh` refuse a PR whose `## Self-review` is missing or names an older sha.
