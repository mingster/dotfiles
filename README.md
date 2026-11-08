# Dotfiles and AI agent team

This repository sets up a developer machine on macOS, Arch Linux or Debian. It also ships the shared roles, scripts and skills that any software project can adopt for an AI agent team.

Each project keeps its own facts in `docs/agents/`. Everything else is linked from this repo.

## What an agent team is

An **agent team** is a small set of AI agents that share one delivery playbook. Terms used below:

* **Orca:** the desktop app that starts, shows and connects the agents.
* **Tracker:** the list of tasks (GitHub issues) the team reads and updates.
* **Grill:** a round of pointed questions that fills the gaps in an idea before anyone builds it.
* **Verifier:** a second AI model that checks a finished change and gives a pass or fail.
* **Babysit:** a check every five minutes on open pull requests that starts a fix or a merge when one is due.
* **Fleet:** the group of computers that run the agents.

One **coordinator agent** holds the CEO role. It reads the issue tracker, plans work, and **dispatches** tasks. A dispatch is a single start command that gives one worker a complete assignment.

**Worker agents** each take one task. They work in their own **worktree**, a separate git checkout so their edits never collide with other tasks. When a worker finishes, it sends **worker_done**, an orchestration message that ends its turn and reports what it did.

The **owner** is the human who approves money, production, irreversible data changes, and a short list of other reserved decisions. Agents run the rest without waiting on chat.

Full role names and boundaries live in [Agent team reference](docs/agents/team-reference.md).

## How one task runs

1. **Issue.** Someone opens a tracker item with acceptance criteria. Intake roles may grill and slice it until it is ready.
2. **Brief.** The coordinator attaches a structured **brief** on the issue (or uses the body). The brief has five parts: `Refs`, Acceptance, Out of scope, Verify and Finish. `script/brief-lint.sh` rejects a brief that lacks any of them.
3. **Worker start.** The coordinator runs `script/worker-startup.sh` (or the matching Orca helper). That checks that the host is ready and that the usage quota allows another worker, then starts one worker in a fresh worktree.
4. **Build.** The worker implements the ticket, runs local checks, commits, pushes once and opens a pull request.
5. **Checks and review.** GitHub Actions runs required checks. A read only bot review and a separate verifier model post a **Verdict** (`PASS`, `PASS+NOTES` or `FAIL`) via `script/post-verdict.sh`.
6. **Merge.** When checks and Verdict match the PR head, `script/ship.sh` may squash merge. A periodic babysit pass can start a fix worker or a shipping run.
7. **Cleanup.** `script/wrap-up.sh` removes finished worktrees and merged branches. The issue closes when the PR merges.

Orca orchestration details, gates and failure limits are in [Coordinator operations](docs/agents/coordinator-operations.md) and [Agent team architecture](docs/agents/agent-team-architecture.md).

## Set up

### Set up a machine

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles
sh mac/osxprep.sh   # macOS only: installs Command Line Tools
sh install.sh
```

`install.sh` links `~/dotfiles`, home dotfiles, editor settings and shared skills, then runs the package script for your system (`mac/`, `arch/` or `debian/`). Safe to re-run: unchanged tools are skipped and conflicting files are backed up.

| Command | Effect |
| --- | --- |
| `DOTFILES_SKIP_SYSTEM_SETUP=1 sh install.sh` | Refresh links without installing system packages |
| `DOTFILES_BREW_UPGRADE=1 sh install.sh` | Also upgrade Homebrew packages on macOS |
| `script/agent-team.sh machine` | Link skills, roles, hooks, bins and model routing into `~/.claude`, and merge settings (add `--dry-run` to preview). CLI install is `script/install-agent-clis.sh`, Orca presets are `script/setup-orca.sh` |

Fleet host registration, pull scripts, automations and the readiness checklist are in [Fleet readiness](docs/agents/team-reference.md#fleet-readiness).

### Adopt the team in a project

`script/agent-team.sh` is the single entry point for machine setup and project adoption.

```bash
script/agent-team.sh machine
script/agent-team.sh project /path/to/project --project-name <name>
script/agent-team.sh sync    /path/to/project
script/agent-team.sh check   /path/to/project
script/agent-team.sh all     /path/to/project
```

| Command | Effect |
| --- | --- |
| `machine` | Link skills, roles, hooks, bins and model routing, and merge settings on this computer |
| `project` | Seed roles, labels, team skills and audit output on a new repository |
| `sync` | Refresh linked roles, hooks, skills and template managed files on an existing repository |
| `check` | Read only drift check on one or more repositories (exit non zero when something diverges) |
| `all` | Run `machine`, then `project` or migration logic for the given directory |

After adoption, fill in project facts:

* `docs/agents/team-facts.md`: repositories, stack and team facts
* `docs/agents/deploy-facts.md`: deploy targets, URLs and smoke commands
* `docs/agents/domain.md`: domain context for planning skills

`bun script/team-audit-metrics.ts --repo <owner/name>` prints the weekly delivery numbers for any project. The weekly audit runs it, and no project keeps its own copy.

See [Agent team setup](docs/agents/team-reference.md#agent-team-setup) for owner login steps and [settings backup](docs/agents/agent-settings-backup.md) for backups.

## Fleet and load

The **fleet** is several computers paired in Orca. One host runs the coordinator agent. Other hosts run builders, reviewers, browser work and heavy checks.

Placement follows the order and per host limits in [Coordinator operations](docs/agents/coordinator-operations.md): primary code host (also the coordinator host), then first overflow host, then second overflow host. Browser and secrets work stays on its dedicated host. The database and heavy host runs databases and remote Playwright or `head-checks.sh` jobs only, never interactive workers.

The **usage gate** (`script/usage-gate.py` and provider hooks) blocks dispatch for a provider at its weekly quota ceiling. The **coordinator overload gate** lives in `script/fleet-watch.py` (`COORDINATOR_MAX_LOAD_PER_CORE`). When the coordinator host's load per core or free memory crosses its limit, no new local worker starts there, and the run points to an overflow host with free room. The coordinator must not dispatch past `NO DISPATCH` lines from `script/elon-startup.sh`.

`script/worker-startup.sh` checks host readiness and the usage gate, then starts the worker. An explicit `--on <environment>` starts it on that host.

Host names, caps and roles come from private fleet configuration, not from hard coded values in this public repo.

## Team guideline (summary)

### Goal

An agent team that follows the [Matt Pocock](https://github.com/mattpocock/skills) and [pstack](https://github.com/cursor/plugins/tree/main/pstack) skill design inside Orca. A ready ticket reaches merge without message relay between agents. Staging updates on a daily schedule; production needs a green staging review and the owner's go.

Principles, targets, the full lifecycle diagram, babysit and shipping rules, role table, owner decisions and review depth are in [Agent team reference](docs/agents/team-reference.md#team-guideline). Per project policy lives in each repo's `docs/agents/team.md`.

### Team files

Canonical team templates live under `templates/agent-team/`. Each project's `docs/agents/` keeps five required files (`issue-tracker.md`, `triage-labels.md`, `domain.md`, `team-facts.md`, `deploy-facts.md`). See [Docs for agent projects](docs/agents/domain.md).

## Tools

These are the only team tools we keep or build. Full contracts live in each project's process spec. The Job and Runs table is in [Agent team reference](docs/agents/team-reference.md#team-tools).

Project hooks stay small: a command guard for production, secrets and destructive commands, the three strike stop and the worker turn limit.

## Engineering workflow

For a change in one repository, use the shared skills in order: intent, grill, spec, tickets, build, review. Stage table and shortcuts are in [Skills inventory](docs/agents/skills-inventory.md) and [SDLC skill map](docs/agents/sdlc-skill-map.md).

| Stage | Skill | What it does |
| --- | --- | --- |
| Intent | `/capture-intent` | The problem and outcome in the owner's words. New features only |
| Grill | `/grill-with-docs` | Interview that finds edge cases and records decisions |
| Spec | `/write-spec` or `/to-spec` | The agreed plan, no second interview |
| Tickets | `/to-tickets` | Small vertical slices with test cases |
| Build | `/implement` or `/tdd` | Bug fixes start with a failing test, then the fix (skip only when expensive, integration heavy or unclear). Features, scripts and refactors require tests and proof on the real artifact (test need not fail first; refactors prove behavior unchanged) |
| Review | `/code-review` | Standards and spec, never skipped |

Shortcuts: a typo or config tweak goes straight to `/tdd` or an edit. A bug starts with `/diagnosing-bugs` until a test goes red. A single slice skips `/to-tickets`.

## Shared skills

All skills live in `.agents/skills/<name>/`, and `install.sh` links them into Claude Code, Cursor and Antigravity. Change one here and every tool gets it.

* **Planning:** `capture-intent`, `grill-me`, `grilling`, `grill-with-docs`, `write-spec`, `to-spec`, `to-tickets`, `wayfinder`, `triage`, `domain-modeling`, `codebase-design`.
* **Building:** `tdd`, `implement`, `code-review`, `diagnosing-bugs`, `prototype`, `improve-codebase-architecture`, `resolving-merge-conflicts`, `laravel-inertia-react-structure`, `create-pr`.
* **Research and docs:** `research`, `retro`, `handoff`, `writing-for-agents`.
* **Environment:** `setup-matt-pocock-skills`, `agent-browser`, `orca-team`, `wizard`. Orca's own skills come from `orca skills install --all`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `install.sh` | Bootstrap for all systems |
| `mac/`, `arch/`, `debian/` | System packages and installers |
| `script/` | Setup scripts and team tools |
| `.agents/skills/` | Shared skills |
| `.agents/claude/` | Global Claude Code configuration |
| `templates/agent-team/` | Roles and team skills adopted into projects |
| `.config/` | Application configuration, managed with GNU Stow |
| `ide/` | Editor settings |
| `docs/agents/` | Deeper docs: [setup](docs/agents/team-reference.md#agent-team-setup), [roles](docs/agents/team-reference.md), [Orca automations](docs/agents/orca-automations.md), [settings backup](docs/agents/agent-settings-backup.md) |
