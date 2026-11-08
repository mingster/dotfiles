# Dotfiles and AI agent team

This repository sets up a developer machine on macOS, Arch Linux or Debian. It also ships the shared roles, scripts and skills that any software project can adopt for an AI agent team.

Each project keeps its own facts in `docs/agents/`. Everything else is linked from this repo.

## What an agent team is

An **agent team** is a small set of AI agents that share one delivery playbook.

One **coordinator agent** holds the CEO role. It reads the issue tracker, plans work, and **dispatches** tasks. A dispatch is a single start command that gives one worker a complete assignment.

**Worker agents** each take one task. They work in their own **worktree**, a separate git checkout so their edits never collide with other tasks. When a worker finishes, it sends **worker_done**, an orchestration message that ends its turn and reports what it did.

The **owner** is the human who approves money, production, irreversible data changes, and a short list of other reserved decisions. Agents run the rest without waiting on chat.

Full role names and boundaries live in [Agent team reference](docs/agents/team-reference.md).

## How one task runs

1. **Issue.** Someone opens a tracker item with acceptance criteria. Intake roles may grill and slice it until it is ready.
2. **Brief.** The coordinator attaches a structured **brief** on the issue (or uses the body). The brief lists `Refs`, scope, verify steps and finish steps. `script/brief-lint.sh` rejects incomplete briefs.
3. **Worker start.** The coordinator runs `script/worker-startup.sh` (or the matching Orca helper). That checks fleet load, usage quota and host readiness, then starts one worker in a fresh worktree.
4. **Build.** The worker implements the ticket, runs local checks, commits, pushes once and opens a pull request.
5. **Checks and review.** GitHub Actions runs required checks. A read only bot review and a separate verifier model post a **Verdict** (`PASS`, `PASS+NOTES` or `FAIL`) via `script/post-verdict.sh`.
6. **Merge.** When checks and Verdict match the PR head, `script/ship.sh` may squash merge. A periodic babysit pass can start a fix worker or a shipping run.
7. **Cleanup.** `script/wrap-up.sh` removes finished worktrees and merged branches. The issue closes when the PR merges.

Orca orchestration details, gates and failure limits are in [Coordinator operations](docs/agents/coordinator-operations.md) and [Agent team architecture](docs/agents/agent-team-architecture.md).

## Set up

### Set up a machine

```bash
mkdir -p ~/src && cd ~/src
git clone <repository-url> dotfiles && cd dotfiles
sh mac/osxprep.sh   # macOS only: installs Command Line Tools
sh install.sh
```

`install.sh` links `~/dotfiles`, home dotfiles, editor settings and shared skills, then runs the package script for your system (`mac/`, `arch/` or `debian/`). Safe to re-run: unchanged tools are skipped and conflicting files are backed up.

| Command | Effect |
| --- | --- |
| `DOTFILES_SKIP_SYSTEM_SETUP=1 sh install.sh` | Refresh links without installing system packages |
| `DOTFILES_BREW_UPGRADE=1 sh install.sh` | Also upgrade Homebrew packages on macOS |
| `script/agent-team.sh machine` | Install agent CLIs, link skills and settings, report missing logins (add `--dry-run` to preview) |

Fleet host registration, pull scripts, automations and the readiness checklist are in [Agent team setup](docs/agents/agent-team-setup.md#fleet-readiness).

### Adopt the team in a project

`script/agent-team.sh` is the single entry point for machine setup and project adoption (see open pull request 756 in this repository).

```bash
script/agent-team.sh machine
script/agent-team.sh project /path/to/project --project-name <name>
script/agent-team.sh sync    /path/to/project
script/agent-team.sh check   /path/to/project
script/agent-team.sh all     /path/to/project
```

| Command | Effect |
| --- | --- |
| `machine` | Configure CLIs, skills, hooks and Orca presets on this computer |
| `project` | Seed roles, labels, team skills and audit output on a new repository |
| `sync` | Refresh linked roles, hooks, skills and template managed files on an existing repository |
| `check` | Read only drift check on one or more repositories (exit non zero when something diverges) |
| `all` | Run `machine`, then `project` or migration logic for the given directory |

After adoption, fill in project facts:

* `docs/agents/team-facts.md`: repositories, stack and team facts
* `docs/agents/deploy-facts.md`: deploy targets, URLs and smoke commands
* `docs/agents/domain.md`: domain context for planning skills

See [Agent team setup](docs/agents/agent-team-setup.md) for backups, reset flows and owner login steps.

## Fleet and load

The **fleet** is several computers paired in Orca. One host runs the coordinator agent. Other hosts run builders, reviewers, browser work and heavy checks.

Before each dispatch the coordinator reads load through `fleet-load.sh` (published under the coordinator state directory). Placement follows the order and per host limits in [Coordinator operations](docs/agents/coordinator-operations.md): primary code host (also the coordinator host), then first overflow host, then second overflow host. Browser and secrets work stays on its dedicated host. The database and heavy host runs databases and remote Playwright or `head-checks.sh` jobs only, never interactive workers.

The **usage gate** (`script/usage-gate.py` and provider hooks) blocks dispatch for a provider at its weekly quota ceiling. The **coordinator overload gate** (issue 748) refuses a new local worker when the coordinator host is over its load or memory limit on the target host. The coordinator must not dispatch past `NO DISPATCH` lines from `script/elon-startup.sh`.

`script/worker-startup.sh` (issue 757) chooses a host automatically when the caller passes no `--on`:

1. Read load for every fleet host from the same source as `fleet-load.sh`.
2. Walk the placement order and limits from [Coordinator operations](docs/agents/coordinator-operations.md).
3. Start on the first host under its limit and print one line with the chosen host and load.
4. When every host is over limit, refuse with one line listing each host's load.
5. An explicit `--on <environment>` is honored unchanged, and the usage gate still applies there.

Host names, caps and roles come from private fleet configuration, not from hard coded values in this public repo.

## Team guideline (summary)

### Goal

An agent team that follows the [Matt Pocock](https://github.com/mattpocock/skills) and [pstack](https://github.com/cursor/plugins/tree/main/pstack) skill design inside Orca. A ready ticket reaches merge without message relay between agents. Staging updates on a daily schedule; production needs a green staging review and the owner's go.

Principles, targets, the full lifecycle diagram, babysit and shipping rules, role table, owner decisions and review depth are in [Agent team reference](docs/agents/team-reference.md#team-guideline). Per project policy lives in each repo's `docs/agents/team.md`.

### Team files

Canonical team templates live under `templates/agent-team/`. Each project's `docs/agents/` keeps five required files (`issue-tracker.md`, `triage-labels.md`, `domain.md`, `team-facts.md`, `deploy-facts.md`). See [Docs for agent projects](docs/agents/domain.md).

## Tools

Scheduled scripts, fleet watch, usage and heavy gates, worker startup, head checks, review helpers, ship, wrap up, deploy and audit tools are listed in [Agent team reference](docs/agents/team-reference.md#tools). Project hooks stay small: command guards, strike limits and worker turn limits.

## Engineering workflow

For a change in one repository, use the shared skills in order: intent, grill, spec, tickets, build, review. Stage table and shortcuts are in [Skills inventory](docs/agents/skills-inventory.md) and [SDLC skill map](docs/agents/sdlc-skill-map.md).

| Stage | Skill | What it does |
| --- | --- | --- |
| Intent | `/capture-intent` | Capture the problem and outcome (new features) |
| Grill | `/grill-with-docs` | Interview that records decisions |
| Spec | `/write-spec` or `/to-spec` | Agreed plan without a second interview |
| Tickets | `/to-tickets` | Small vertical slices with test cases |
| Build | `/implement` or `/tdd` | Tests first where required, then implementation |
| Review | `/code-review` | Standards and spec |

## Shared skills

All skills live in `.agents/skills/<name>/`. `install.sh` links them into Claude Code, Cursor and Antigravity.

* **Planning:** `capture-intent`, `grill-me`, `grilling`, `grill-with-docs`, `write-spec`, `to-spec`, `to-tickets`, `wayfinder`, `triage`, `domain-modeling`, `codebase-design`.
* **Building:** `tdd`, `implement`, `code-review`, `diagnosing-bugs`, `prototype`, `improve-codebase-architecture`, `resolving-merge-conflicts`, `laravel-inertia-react-structure`, `create-pr`.
* **Research and docs:** `research`, `retro`, `handoff`, `writing-for-agents`.
* **Environment:** `setup-matt-pocock-skills`, `agent-browser`, `orca-team`, `wizard`. Orca bundled skills: `orca skills install --all`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `install.sh` | Bootstrap for all systems |
| `mac/`, `arch/`, `debian/` | System packages and installers |
| `script/` | Setup scripts and team tools |
| `.agents/skills/` | Shared skills |
| `.agents/claude/` | Global Claude Code configuration |
| `templates/agent-team/` | Roles and team skills copied or linked into projects |
| `.config/` | Application configuration (GNU Stow) |
| `ide/` | Editor settings |
| `docs/agents/` | Deeper docs: [setup](docs/agents/agent-team-setup.md), [roles](docs/agents/team-reference.md), [Orca automations](docs/agents/orca-automations.md), [settings backup](docs/agents/agent-settings-backup.md) |
