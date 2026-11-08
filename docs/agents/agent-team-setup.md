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

Machine setup configures Claude Code, Cursor, Antigravity, Orca and shared
skill links. Verification reports missing commands and owner login steps without
reading credential files. Missing owner prerequisites are warnings; a failed setup
script is an error. Use `--dry-run` to preview machine setup without running it.

## Fleet readiness

After `install.sh` finishes on a host, add it to the private `~/agent-state` repository and register its scheduled Orca jobs.

Roles live in `~/agent-state/coordinator.conf` with one `coordinator <name>` line for the active coordinator and ordered `backup <name>` lines for backup hosts, where `<name>` matches `hostname -s`. Every host in the fleet keeps a clean `main` checkout of `~/agent-state` and the configured project repositories.

```bash
~/dotfiles/script/fleet-pull.sh
~/dotfiles/script/fleet-toolchain-check.sh
~/dotfiles/script/install-fleet-automations.sh --dry-run --install
~/dotfiles/script/install-fleet-automations.sh --install
~/dotfiles/script/install-fleet-automations.sh --status
```

| Command | Effect |
| --- | --- |
| `script/fleet-pull.sh` | Fast-forward `main` in `~/agent-state` and each configured repository on every host. Prints `ok` with the short commit, or exits non-zero with `fail <host> <repo>` when a checkout is `dirty`, `not on main: detached` (or on another branch), `diverged: not fast-forward`, `behind after pull`, or unreachable |
| `script/fleet-toolchain-check.sh` | Compare CLI versions across fleet hosts against the coordinator in `coordinator.conf` and the latest release (add `--apply` to align `.tool-versions` pins and upgrade supported tools) |
| `script/install-fleet-automations.sh --dry-run --install` | Print the planned `orca automations` commands without changing Orca |
| `script/install-fleet-automations.sh --install` | Create or update the six fleet automations on this host (safe to run again) |
| `script/install-fleet-automations.sh --status` | Print enabled or disabled status for each fleet automation on this host |
| `script/worker-startup.sh --host-check` | Verify `~/dotfiles`, Orca presets, repository checkouts and runtime pins before the host takes work |

Each automation runs a shell precheck that exits `1` when done, so Orca starts no agent session and spends no AI quota. Orca caps every precheck at 600 seconds (`wrap-up-scheduled` and `weekly-update` bound their timeouts so each run finishes inside the 600 second cap). When `~/dotfiles` is a symlink on a host, `install-fleet-automations.sh` resolves the canonical path and matches the checkout in Orca by repository ID. Hosts without the Orca app installed (such as a headless host) are skipped with a clear message and exit `0`.

| Automation | Schedule | Enabled where |
| --- | --- | --- |
| `fleet-watch` | `*/5 * * * *` | Coordinator only |
| `fleet-toolchain` | `0 5 * * *` | Coordinator only |
| `wrap-up-scheduled` | `*/10 * * * *` | Every Orca host (skipped on a headless host without the Orca app) |
| `sync-team-skills-drift` | `0 6 * * *` | Created disabled for the owner to turn on |
| `team-audit-weekly` | `0 7 * * 1` | Created disabled for the owner to turn on |
| `weekly-update` | `0 8 * * 1` | Created disabled for the owner to turn on |

Readiness checklist for a fleet host:

* [ ] `hostname -s` is set under `coordinator` or `backup` in `~/agent-state/coordinator.conf` and listed in the fleet pull config.
* [ ] `~/dotfiles/script/fleet-pull.sh` prints `ok` for `~/agent-state` and every configured repository on every host, with no `dirty` or `detached` checkouts.
* [ ] `~/dotfiles/script/fleet-toolchain-check.sh` reports all required CLIs present and aligned with the coordinator.
* [ ] `~/dotfiles/script/install-fleet-automations.sh --status` shows `wrap-up-scheduled` enabled on every Orca host, `fleet-watch` and `fleet-toolchain` enabled on the coordinator only, and `sync-team-skills-drift`, `team-audit-weekly` and `weekly-update` created disabled for the owner to turn on (or skips cleanly on a headless host without the Orca app).
* [ ] `~/dotfiles/script/worker-startup.sh --host-check` passes cleanly.

See [Orca automations](orca-automations.md), [Fleet watch](fleet-watch.md) and [Coordinator operations](coordinator-operations.md) for full details.


Missing provider CLIs are installed once using `install_claude.sh`, the official
Cursor and Antigravity installers. Installer references:
[Claude Code](https://code.claude.com/docs/en/setup),
[Cursor](https://cursor.com/docs/cli/installation) and
[Antigravity](https://antigravity.google/docs/cli/install/).
Existing differing configuration files are moved to `<file>.bak.<date>` before
replacement. `setup-orca.sh` links `~/.orca/presets.json` to `~/dotfiles/.orca/presets.json`
after backing up any differing file. Usage gate (`usage-gate-hook.py`) and worker budget
(`worker-budget.py`) hooks are composed into Claude Code, Cursor and Antigravity hook
files via `setup-agent-hooks.sh`. Logins and credentials are never migrated or inspected.
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
`script/weekly-update.sh` (which refreshes Matt Pocock skills, pstack template skills,
Bun and Node LTS across three tested PRs and one summary for the owner's go) or
`script/sync-mattpocock-skills.sh`; project setup never refreshes upstream or
changes the dotfiles checkout. No command commits or pushes the target project.

## Merging through lead-merge.sh

A merge worker Elon dispatches runs `script/lead-merge.sh --repo owner/name --pr N --head <sha>`
(or `--batch <N> <N>` once per wake from the `lead-elon` worktree, and `--mechanical`
for docs-only PRs); Elon dispatches the worker only.
The script refuses unless the caller's worktree is `lead-*` under `~/orca/workspaces/`, the PR is
open on `main` at exactly that head, mergeable, off the protected branches, and free of owner
only files (`.claude/hooks/`, `.claude/settings.json`, `bin/owner-approve.sh`, `*.rules`,
and intents that become Accepted). Orca sets no role variable (`ORCA_TERMINAL_HANDLE` and
`ORCA_AGENT_SESSION_ID` exist for every agent), so the worktree name is the merge check.

## Scheduled wrap-up (macOS)

`script/wrap-up.sh --scheduled` runs one wrap-up round on this host. A round takes a lock (one per host,
under `~/.local/state/agent-team/`), finds the orca CLI, checks that `orca status --json` reports ready,
skips when the 1 minute load divided by the cores is 0.7 or more, then runs `wrap-up.sh --apply` for each
git repo in `orca repo list`. There is no config file. A manual wrap-up run does not take the lock;
wrap-up's own guards recheck before each delete.

The schedule shell is bare, so the round looks for orca itself: the Orca app first, then `PATH`,
`~/.local/bin`, Homebrew, and `~/.orca/cli/bin` last, because that copy can be a stale remote CLI.

Each round writes one line to `~/.orca/logs/wrap-up-scheduled.log`: `round ok`, `skip:` or `round failed:`.
Per repo output goes to `wrap-up-scheduled-detail.log` beside it. No CLI, an unreadable repo list or load,
a repo that fails, and a round over 4 minutes all count as failed. Repos not reached in time are not started.
Each log keeps one rotated copy (`.1`) once it passes 5 MB.

Two failed rounds in a row open one GitHub issue on the repo in `WRAP_UP_ISSUE_REPO`, titled
`wrap-up: scheduled rounds failing on <host>`, with home paths masked. While an issue with that title
is open, no second one is opened. With the variable unset, or a repo that is not private, the round
logs that and opens nothing, so host names stay out of public repos. A repo run hung past its budget
plus 30 seconds is stopped with its inner calls and counts as failed. A scheduled round leaves a shell
no dispatch owns alone; a manual run still closes it after 10 minutes without output.

Install on a host:

1. Copy `templates/launchd/life.example.wrap-up.plist` to
   `~/Library/LaunchAgents/life.example.wrap-up.plist` and replace `__HOME__` with an absolute home path and `__ISSUE_REPO__` with a private `owner/repo`.
   Do not add `ORCA_CLI_COMMAND`: the round clears it, because wrap-up refuses `--apply` when it is set.
2. Load it: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/life.example.wrap-up.plist`.

Unload it: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/life.example.wrap-up.plist`.

Proof: `launchctl print gui/$(id -u)/life.example.wrap-up` shows the job with `run interval = 600 seconds`.
To see a round without waiting, run `launchctl kickstart gui/$(id -u)/life.example.wrap-up`, then read
`~/.orca/logs/wrap-up-scheduled.log` for a `round ok` line.

## Interpreters (asdf)

The root `.tool-versions` pins python and nodejs. Every host runs both through asdf, so
`python3` and `node` resolve the same way everywhere. Scripts keep `#!/usr/bin/env python3`
and never hardcode an interpreter path.

The owner runs the bootstrap once per host:

```bash
bash ~/dotfiles/script/bootstrap-asdf-tools.sh
```

It installs asdf if missing, adds the plugins, installs the pinned versions, writes the same
pins into `~/.tool-versions`, and prints the resolved `python3` and `node`. A second run
changes nothing and says so. Pass `--dotfiles <dir>` to read the pins from another checkout.

Tests that set `HOME` to a temp dir source `script/tests/lib/asdf-pin.sh` (python tests import
`asdf_pin.py`) first. It exports the version pins and `ASDF_DATA_DIR`, since asdf looks for its
installs under `$HOME/.asdf`. `script/tests/asdf-pin-coverage.test.sh` fails when a test skips it.
