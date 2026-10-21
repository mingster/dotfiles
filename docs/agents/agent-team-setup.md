# Agent team setup

Use `script/agent-team.sh` as the entry point for machine setup and project adoption.
The command composes the existing setup, adoption, tracker initialization, skill sync
and audit scripts. Run `script/agent-team.sh --help` for the supported commands.

```bash
script/agent-team.sh machine
script/agent-team.sh project /path/to/project --project-name acme
script/agent-team.sh reset /path/to/project
script/agent-team.sh reset /path/to/project --apply
script/agent-team.sh all /path/to/project
```

Machine setup configures Claude Code, Codex, Cursor, Antigravity, Orca and shared
skill links. Verification reports missing commands and owner login steps without
reading credential files. Missing owner prerequisites are warnings; a failed setup
script is an error. Use `--dry-run` to preview machine setup without running it.

Missing provider CLIs are installed once using `install_claude.sh`, the official
Cursor and Antigravity installers, and `npm install -g @openai/codex`. If npm is
missing, install Node.js and retry. Installer references:
[Claude Code](https://code.claude.com/docs/en/setup),
[Codex](https://help.openai.com/en/articles/11096431),
[Cursor](https://cursor.com/docs/cli/installation) and
[Antigravity](https://antigravity.google/docs/cli/install/).
Existing differing configuration files are moved to `<file>.bak.<date>` before
replacement. Usage gate and worker budget hooks are composed from the existing
Claude hook templates. Logins and credentials are never migrated or inspected.
Orca installation and sign in remain owner steps when its CLI is missing.

Project adoption runs `adopt-agent-team.sh`, `init-agent-project.sh --labels`,
`sync-team-skills.sh` and `team-audit.sh`. The owner or architect must review
`docs/agents/team.md` and fill in
`docs/agents/team-facts.md`, `docs/agents/deploy-facts.md` and
`docs/agents/domain.md`, then establish the project's domain context and deployment
commands. Label creation requires GitHub access. Audit findings remain visible and
return a failing status for review.

Reset defaults to a preview and requires a clean Git working tree, including
untracked files. `--apply` leaves changes uncommitted for review. Product facts,
domain context, ADRs and intents stay project owned. Customized role files are
preserved and reported for manual reconciliation when they cannot be safely
refreshed. Never put product facts in generated team skills.
Conflicts show only line counts, preserving the whole customized role. A saved
template hash permits safe refresh of roles that have no local edits. Existing
roles without a saved baseline are preserved whenever they differ. Reset also
refreshes the Token budget, Compact instructions and Owner context commands
sections in `AGENTS.md`, keeping other project instructions.

`all` configures the machine first, then selects project adoption or reset based on
the project's team files. Existing projects retain reset's preview default; use
`--apply` for an explicit reset. `all --dry-run` previews both stages.

The commands use the vendored skills already in dotfiles. Updating that snapshot
from upstream is a separate maintainer operation through
`script/sync-mattpocock-skills.sh`; project setup never refreshes upstream or
changes the dotfiles checkout. No command commits or pushes the target project.

## Letting the Tech Lead merge

`~/.codex/rules/default.rules` forbids `gh pr merge` for every Codex worker. The Tech Lead
(a Codex session) merges only through `script/lead-merge.sh --repo owner/name --pr N --head <sha>`.
The script refuses unless the caller's worktree is `lead-*` under `~/orca/workspaces/`, the PR is
open on `main` at exactly that head, mergeable, off the protected branches, and free of owner
only files (`.claude/hooks/`, `.claude/settings.json`, `bin/owner-approve.sh`, `.codex`, `*.rules`,
and intents that become Accepted). Orca sets no role variable (`ORCA_TERMINAL_HANDLE` and
`ORCA_AGENT_SESSION_ID` exist for every agent), so the worktree name is the tech-lead check.

The owner allows the script once by appending the rendered template (the sed command replaces the home placeholder) to the live rules, then checks the result:

```bash
sed "s|__HOME__|$HOME|g" ~/dotfiles/templates/codex/lead-merge.rules >> ~/.codex/rules/default.rules
```

Agents never edit `~/.codex` themselves. The forbidden `gh pr merge` rule stays in place.

## Optional worker watchdog (macOS)

Copy `templates/launchd/life.example.worker-watchdog.plist` to
`~/Library/LaunchAgents/life.example.worker-watchdog.plist`. Replace `__HOME__` with
an absolute home path, `__ORCA_CLI__` with the absolute path from `command -v orca`,
`__RUN_ID__` with the run to monitor, and `__NOTIFY_HANDLE__` / `__NOTIFY_RUN_ID__`
with the escalation recipient's terminal handle and owning run. Add more
`--run`, run ID pairs to `ProgramArguments` to monitor several runs.

After reviewing the file, load it with
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/life.example.worker-watchdog.plist`.
Unload it with
`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/life.example.worker-watchdog.plist`
before changing run IDs or notification handles. This is an opt-in install;
project adoption does not load the service.

The KeepAlive job checks rendered coordinator and live worker screens every 90
seconds, nudges after two idle checks (at most once per terminal per ten minutes),
and escalates provider limits, three idle checks after a nudge, or three checks
with no live workers. Counters and cooldowns survive restarts in
`~/.orca/state/worker-watchdog/`; action lines go to
`~/.orca/logs/worker-watchdog.log` without terminal text. It never stops workers.
For a bounded foreground diagnostic, use
`bash ~/dotfiles/script/worker-watchdog.sh --run RUN --notify HANDLE --notify-run RUN --checks 3`.
The only gate block is fresh real provider usage plus running worker reserve at
the weekly/cycle ceiling; daily pacing is advisory, and failed provider refreshes
report unknown with the source and reason. A watchdog nudge does not replace the
coordinator's screen check on every wake.
