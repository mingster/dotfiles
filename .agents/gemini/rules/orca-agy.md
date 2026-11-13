# Antigravity (agy) and Orca across projects

1. **Project memory (`MEMORY.md`):** `agy` does not auto-load Claude Code's `MEMORY.md` at startup. When project history or past decisions matter, check `~/.claude/projects/<encoded-repo-path>/memory/MEMORY.md` (for example `-Users-example-GitHub-dotfiles`).
2. **Commits and publication:** in any agent team worktree, commit with `git -c user.email="mingster@users.noreply.github.com" commit -m "..."`. The PR owner pushes, opens the PR and merges it with `~/dotfiles/script/ship.sh` (`templates/agent-team/docs/agents/team.md`, Publication).
3. **Notifying the coordinator via Orca orchestration:**
   - Read the active coordinator Run ID from `~/.claude/state/fleet-watch-elon.json` (`runs[0].id` and `runs[0].terminal`) or `orca orchestration run-list --json`.
   - If the current `agy` terminal is the exact process owning an active Dispatch, report with `orca orchestration send --run <run_id> --from "$ORCA_TERMINAL_HANDLE" --type worker_done --outcome succeeded --task-id <task_id> --dispatch-id <dispatch_id> ...`.
   - If the `agy` terminal is an interactive pane or its dispatch already settled (`worker_identity_changed`), send `--type status` to `run:<run_id>` so the coordinator's waiter wakes immediately:
     ```bash
     orca orchestration send \
       --to run:<run_id> \
       --run <run_id> \
       --from "$ORCA_TERMINAL_HANDLE" \
       --type status \
       --subject "<role>: <branch> ready (<40-char sha>)" \
       --body "Worktree: <path>\nBranch: <branch>\nHEAD: <40-char sha>\nDiff stat: ...\nVerification: ..." \
       --json
     ```
4. **Public repository hygiene (`dotfiles`):** never write private project names, company names, or fleet hostnames in `dotfiles` docs, commits, or PR descriptions (`script/tests/no-project-names.test.sh`), and never use dashes (`—` or ` - `) as punctuation in markdown docs or READMEs.
