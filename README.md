# Ming's Dotfiles and AI Agent Team

This repository does two jobs. It sets up a machine on macOS, Arch Linux or Debian. It also holds the basic guideline, tools and skills for an AI agent team that any project can adopt.

Each project uses what lives here as much as it can, and keeps only its own facts.

## 1. Set up a machine

```bash
mkdir -p ~/GitHub && cd ~/GitHub
git clone https://github.com/mingster/dotfiles.git && cd dotfiles
sh mac/osxprep.sh   # macOS only: installs Command Line Tools
sh install.sh
```

`install.sh` links `~/dotfiles`, your home configuration files and the shared skill folders, sets up editors, and runs the package script for your system (`mac/`, `arch/` or `debian/`). You can run it again safely. Unchanged tools are skipped and conflicting files are backed up.

| Command | Effect |
| --- | --- |
| `DOTFILES_SKIP_SYSTEM_SETUP=1 sh install.sh` | Refresh links without installing system packages |
| `DOTFILES_BREW_UPGRADE=1 sh install.sh` | Also upgrade Homebrew packages on macOS |
| `script/agent-team.sh machine` | Check agent tools on this machine (add `--dry-run` to preview) |

## 2. Adopt the team in a project

```bash
~/dotfiles/script/agent-team.sh project /path/to/project --project-name acme
```

This copies the roles and skills, sets up the issue tracker labels, writes the team skills into the project and runs an audit. Then fill in two files with the project's own facts:

* `docs/agents/team-facts.md`: repositories, stack and team facts.
* `docs/agents/deploy-facts.md`: deploy targets, URLs and smoke test commands.

## 3. The team guideline

### Goal

An agent team that follows the [Matt Pocock](https://github.com/mattpocock/skills) and [pstack](https://github.com/cursor/plugins/tree/main/pstack) skills and their design, in Orca ADE. A ticket goes from ready to merged with no agent relaying a message and no human in the loop. Main reaches staging every day by itself. Production needs a green staging review and the owner's go.

### Principles

* Use Orca, pstack and Matt Pocock skills as they are. Customize only when we must, and record why.
* Improve what exists before adding anything. Team rules and scripts must not grow in total.
* Each role takes the shortest path that still reaches the targets.
* When speed and quality conflict, quality wins for money, sign-in, database schema and hooks. Everything else takes the fast lane, and daily staging is the second line of defence.
* State lives only in GitHub and Orca. After a restart the team carries on from there.

### Targets

| Measure | Target |
| --- | --- |
| Start to merge, median | 60 minutes or less |
| Checks fail on first pass | 15% or less |
| Reopened or hotfix | 2% or less |
| P0 reaching production | 0 per month |
| Ready to worker start | 15 minutes |
| Build | 40 minutes |
| Checks | 10 minutes |
| Review | 10 minutes |
| Daily staging tests | 15 minutes |
| `heavy-gate` wait, median | 2 minutes or less |
| Worktrees on a host | Running workers plus a fixed list |

Missing data reads as unknown, never zero.

### Lifecycle

Each step is one run that does one job and ends. It never waits on a person or another agent. The next run reads GitHub.

```mermaid
flowchart TD
    Req["Request from the owner or Elon"] --> Intake["Intake: architect-pm grills with Elon"]
    Intake --> Design["Design, features only: one document, one owner approval"]
    Intake & Design --> Ready["Issue is ready"]
    Ready --> Build["Build: fullstack-dev, TDD, local checks, pushes and opens PR"]
    Build --> Checks["Actions Checks"]
    Checks --> Review["Actions Review and verifier Verdict (another model family)"]
    Review --> Babysit["5 minute babysit pass"]
    Babysit -->|"Fix needed"| Build
    Babysit --> Ship["Shipping run (script/ship.sh): squash merge and read back"]
    Ship --> Wrap["Wrap-up: 10 minute Orca automation"]
    Ship --> Staging["Staging: daily at 19:00, staging review, full regression"]
    Staging --> Go["Owner's go"] --> Prod["Production: backup, deploy, smoke"]
```

| Step | Starts when | Who | Done when |
| --- | --- | --- | --- |
| Intake | A request arrives | architect-pm with Elon. Sales joins for UI or wording, support for support matters | Issue is ready, or closed as a duplicate |
| Design | Intake says it is a feature | Same people, with `capture-intent`, grill, spec and tickets | One document, one owner approval |
| Build | The 5 minute run finds a ready issue that passes the gates | fullstack-dev | Touched checks green locally, PR open and pushed once |
| Actions Checks | Push to a PR | GitHub Actions | Required checks pass (`head-checks` on app repos) |
| Actions Review | Actions Checks pass | `script/pr-review.sh` in GitHub Actions, read only | Bot review comment and `review` status posted |
| Verifier Verdict | Actions Checks pass | `qa-sdet` (another model family, runs parent against head as a user would) | `Verdict: PASS` or `PASS+NOTES` posted via `script/post-verdict.sh` |
| Babysit | 5 minute babysit pass on each open PR in `check` mode | `fleet-watch.py` | Starts one fix worker (fixes and pushes once) or a Shipping run |
| Shipping run | Checks pass and verifier Verdict matches head `git patch-id` | `script/ship.sh` | Squash merge (`gh pr merge --squash`) and PR read back as merged |
| Wrap-up | Every 10 minutes on each host | Orca automation (`script/wrap-up.sh`) | Finished worktrees, terminals and merged branches read back as gone |
| Staging and review | Daily at 19:00 Taiwan time | `release-manager`, then `qa-sdet` and full regression | Latest main deployed, staging review and regression green (or issue opened) |
| Production | Owner's go | `release-manager` | Backup, deploy and smoke pass, or code rolls back |

**Babysit.** Every 5 minutes fleet-watch looks at each open PR once and puts it in one of three groups.

* Ready: checks are green and a verifier PASS covers this head. It starts a Shipping run.
* Needs a fix: a conflict with main, an unresolved review thread, a review FAIL, or a red check on a file the PR changed. It starts one fresh fix worker, which fixes, pushes once and ends. One PR never has two fix workers at once.
* Anything else waits for the next pass.

**Shipping run.** One run of `script/ship.sh` handles one PR. It merges only when all of these hold:

* The PR is open and mergeable, and every check passed.
* The newest Verdict is PASS or PASS+NOTES, from a real verifier who is not the author.
* The Verdict covers this head, or a rebase of it with the same patch id.
* Changes to protected paths carry the owner's approval.

It squash merges, reads the PR back as merged and ends. If any condition fails, it prints one line saying why and merges nothing.

**Who can send a request.** The owner and Elon. Sales and support send requests to Elon, and Elon gets the owner's approval before passing one to architect-pm.

**Start rule.** An issue starts when it has `ready-for-agent`, acceptance criteria and no blocker, and the usage and load gates pass. `P0` and `P1` go first, then first in, first out. A worker starts only from a complete brief: `Refs` to the issue, acceptance criteria, out of scope, verify and finish. The issue scan takes the newest Agent Brief comment (else the issue body) and adds `Refs`, verify and finish itself. `script/brief-lint.sh` checks the brief at every start, and an issue that fails gets `needs-triage` instead of a worker. A change to the brief goes to the issue, never in a message after the worker is done.

**Failure.** A worker with no progress for 30 minutes restarts once. The same error fixed 3 times stops the work. Review sends a PR back at most 2 times. Past any limit a label goes to Elon.

**Wrap-up.** A finished worker loses its terminal and worktree. A merged or closed PR loses its branches and anything left. Work that exists nowhere else is kept and listed for Elon.

**Deploy safety.** Schema changes stay backward compatible. Production always backs up first, and a failed backup stops the deploy. If smoke fails, code rolls back by itself, and the database waits for the owner.

### Roles

| Role | Job |
| --- | --- |
| Owner | Decides the items listed under Owner decisions |
| Elon | The owner's window and only contact. Off the main line: the lifecycle runs without it. Answers "what now" and "recap", handles exceptions, sets priorities weekly |
| `architect-pm` | Intake, the design document, the weekly list, full audits |
| `fullstack-dev` | Builds one ticket with tests by TDD |
| `qa-sdet` | Verifier Verdict, Playwright runs and the staging review |
| `release-manager` | Staging on schedule, production on the owner's go |
| `secops-finops` | Its check is part of Strong review. Weekly reconciliation |
| `sales-marketing` | Joins the grill for UI and wording. Sends requests to Elon |
| `support-csm` | Joins the grill for support matters. Sends requests to Elon. Replies go out only after the owner approves |

### Team files

The team docs live once, in `~/dotfiles/templates/agent-team/`. Role files and skills read them there by path, and no project keeps a copy.

A project's `docs/agents/` holds only five files, because shared skills, scripts and hooks read them by a fixed path:

* `issue-tracker.md`, `triage-labels.md`, `domain.md`: read by the Matt Pocock skills and `init-agent-project.sh`.
* `team-facts.md`: the project's own team facts, such as hosts, lanes, times and its differences from `team.md`.
* `deploy-facts.md`: deploy targets and production hosts, read by the deploy skill.

Anything else in a project's `docs/agents/` is a special case that needs the owner's approval, recorded in an ADR. Area notes go in `docs/<area>/`, history stays in git and GitHub, and learnings go to auto memory.

### Owner decisions

New features and pages, prices and money rules, production go, irreversible data changes, budget and legal commitments, paid usage overage, the weekly update PRs, and role file and hook changes. Nothing else interrupts the owner.

### Review

A builder never reviews its own PR. Review has two layers after Actions Checks pass: the read only bot review in Actions (`script/pr-review.sh`) and the verifier Verdict (`qa-sdet` from another model family running the change as a user would, parent against head, posted via `script/post-verdict.sh`). Review checks the diff against `## Scope` and answers three questions: does the diff meet each acceptance line, is there a real bug, would the new test go red without the fix. The first round lists every finding; later rounds check only earlier points plus the new diff. Style is never a FAIL. A flake reruns the job once, never an empty commit.

Standard depth is one read. Strong depth adds a stronger model and the security check for money, sign-in, schema, hooks and workflows. A script picks the depth from the file list. Changes only to docs and changelog pass with no agent.

## 4. Tools

These are the only team tools we keep or build. Full contracts live in each project's process spec.

| Tool | Job | Runs |
| --- | --- | --- |
| Orca automation | Starts every scheduled script. A script only job uses a precheck, so it spends no AI quota | On schedule |
| [`fleet-watch.py`](script/fleet-watch.py) | The 5 minute run: copies usage readings, reruns failed workflows once, finds stuck workers, checks backups, starts ready issues, runs the babysit pass | Every 5 minutes on the coordinator |
| [`usage-gate.py`](script/usage-gate.py) | Blocks a worker start at 95% of a weekly limit or with no fresh reading. Paid overage needs the owner's approval with an amount and an expiry | Every worker start |
| [`heavy-gate.py`](script/heavy-gate.py) | Holds Playwright and production builds on each host; type checks use measure mode with no slot | Every Playwright run, build and full `tsc` |
| `worker-startup` | Brings a host and worktree up to date, then starts the worker. A host that cannot be fixed takes no work | Daily, and before each worker |
| [`head-checks.sh`](script/head-checks.sh) | Runs a repository's checks on a trial merge of one head with main | Every PR push |
| Review and Verdict | Actions Review (`script/pr-review.sh`) and verifier Verdict ([`post-verdict.sh`](script/post-verdict.sh)) | After Checks pass |
| [`ship.sh`](script/ship.sh) | Shipping run: checks `git patch-id` against the verifier Verdict, squash merges and reads the PR back as merged | When Checks and Verdict pass |
| [`wrap-up.sh`](script/wrap-up.sh) | Clears finished work. Never deletes the last copy. Add `--apply` to run it by hand | Every 10 minutes on every host |
| `/deploy` | Moves a commit to staging or production | Daily, or on the owner's go |
| `/staging-review` | Smoke, tests for what changed, changed pages on phone size. Every page weekly | After each staging deploy |
| Test selection | Compares with the last green staging commit and follows real imports | Every staging review |
| Weekly update | Matt Pocock and pstack upstream, bun and Node. Three tested PRs, a skill-impact draft on the skill PR branches, and report-only software lines in the stdout summary. Merged only on the owner's yes | Weekly |
| [`team-audit.sh`](script/team-audit.sh) | Checks team files and reports the target numbers | Weekly one line result, full audit on the owner's word |
| `/elon status` | "what now": waiting on the owner, running, problems. "recap": merged, deployed, problems and numbers | Only on request |
| Agent state backup | Private repository with memory, schedules and host config, used to rebuild the coordinator | Every 10 minutes |

Project hooks stay small: a command guard for production, secrets and destructive commands, the three strike stop and the worker turn limit.

## 5. Engineering workflow

For a change in one repository, use the skills in order.

| Stage | Skill | What it does |
| --- | --- | --- |
| Intent | `/capture-intent` | The problem and outcome in the owner's words. New features only |
| Grill | `/grill-with-docs` | Interview that finds edge cases and records decisions |
| Spec | `/write-spec` or `/to-spec` | The agreed plan, no second interview |
| Tickets | `/to-tickets` | Small vertical slices with test cases |
| Build | `/implement` or `/tdd` | Red, green, refactor |
| Review | `/code-review` | Standards and spec, never skipped |

Shortcuts: a typo or config tweak goes straight to `/tdd` or an edit. A bug starts with `/diagnosing-bugs` until a test goes red. A single slice skips `/to-tickets`.

## 6. Shared skills

All skills live in `.agents/skills/<name>/`, and `install.sh` links them into Claude Code, Cursor and Antigravity. Change one here and every tool gets it.

* **Planning:** `capture-intent`, `grill-me`, `grilling`, `grill-with-docs`, `write-spec`, `to-spec`, `to-tickets`, `wayfinder`, `triage`, `domain-modeling`, `codebase-design`.
* **Building:** `tdd`, `implement`, `code-review`, `diagnosing-bugs`, `prototype`, `improve-codebase-architecture`, `resolving-merge-conflicts`, `laravel-inertia-react-structure`, `create-pr`.
* **Research and docs:** `research`, `retro`, `handoff`, `writing-for-agents`.
* **Environment:** `setup-matt-pocock-skills`, `agent-browser`, `orca-team`, `wizard`. Orca's own skills come from `orca skills install --all`.

## 7. Repository layout

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
| `docs/agents/` | Deeper docs: [setup](docs/agents/agent-team-setup.md), [roles](docs/agents/team-reference.md), [Orca automations](docs/agents/orca-automations.md), [settings backup](docs/agents/agent-settings-backup.md) |
