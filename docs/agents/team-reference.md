# Agent team reference

Long reference moved out of the root [README](../../README.md). Read it when you need the full role list, the project file map, the per stage command table, or the skill sharing rules.

## Agent team template

Use `script/agent-team.sh` for machine setup, new projects and safe reset previews. See [Agent team setup](agent-team-setup.md) for commands, backups and owner steps.

The team files give agents their jobs, working rules and repeatable steps. Elon is the front door: give him an objective and he plans, dispatches teammates through Orca orchestration and collects their results. See [Agent team architecture](agent-team-architecture.md) for the full design.

`script/adopt-agent-team.sh [--project-name <name>] <dir>` installs from [templates/agent-team](../../templates/agent-team/): roles, generated team skills, facts file skeletons, settings, hooks, model routing and a Token budget block for `AGENTS.md`. Review the project copies and fill in their facts before using the team.

Role instructions live at `<project>/.claude/agents/<role>.md`. Give workers their role file path in the task prompt, including workers on other providers.

| Role | Owns |
| --- | --- |
| `elon` | Priorities, delegation, owner decisions, pushing branches, opening PRs and merging. |
| `tech-lead` | Engineering coordination, local branch integration, worktree cleanup and release coordination. |
| `architect-pm` | User problems, intent, requirements, specs and tickets. |
| `fullstack-dev` | Features and fixes built with tests first, committed on its own branch. |
| `qa-sdet` | Regression tests, independent reviews and checks after deployment. |
| `release-manager` | Local, staging and production deployments, release evidence and rollback plans. |
| `sales-marketing` | Self service acquisition, positioning, conversion experiments and business metrics. |
| `secops-finops` | Security, tenant isolation, financial reconciliation, cost and privacy reviews. |
| `support-csm` | Customer ticket triage, reply drafts, recurring pain points and closure drafts. |

The adoption script installs every role in the template, including support.

Team skills come from [templates/agent-team/.agents/skills](../../templates/agent-team/.agents/skills/): `elon` is the entry point, `ceo` is its alias, `crew` coordinates delivery, `teddy` handles engineering requests, `deploy` promotes releases, `grill-backlog` clears owner decisions and `team-audit` checks team files. Adoption runs `script/sync-team-skills.sh` to generate project `.agents/skills/` copies with links from `.claude/skills/` and `.cursor/skills/`. Edit the template source and sync again; do not edit generated copies.

Team skills add project policy and call Orca and Matt Pocock skills for shared procedures. The [ownership and overlap decisions](skill-overlap-decisions.md) cover every owned skill and explain which steps belong upstream.

Other project files tell the team how this repo works:

| File | What to set or read |
| --- | --- |
| `.claude/model-routing.md` | Provider and model choices, worker launch rules, usage limits and who may push or merge. |
| `.claude/settings.json`, `.claude/hooks/` | Claude session setup, Bash safeguards and repeated test failure limits; `session-start.md` puts Elon at the front door. Other providers follow their own controls and the role instructions. |
| `docs/agents/team.md` | Team roles, orchestration, reporting, handoffs, hotfix loop, rules and gated actions. |
| `docs/agents/team-facts.md` | Repository, check commands, review rules and project shortcuts. |
| `docs/agents/deploy-facts.md` | Components, hosts, stage commands, production approval and rollback steps. |
| `docs/agents/issue-tracker.md` | Where specs and tickets go and how to read or update them. |
| `docs/agents/triage-labels.md` | The project's issue labels and what each means. |
| `docs/agents/domain.md` | Where agents read domain terms and design decisions. |

Adoption creates `team.md`, `team-facts.md` and `deploy-facts.md` if missing. Create the tracker, label and domain files separately with `~/dotfiles/script/init-agent-project.sh --labels <dir>` before using the ticket and review skills. Configure `docs/agents/daily-run.md` in the project before asking for a daily run. Decisions belong in `docs/adr/`.

Use slash commands below in Claude Code, Cursor and Antigravity; in Codex use `$skill-name` with the same arguments. A worker prompt can instead name the skill's `SKILL.md` path and ask it to follow the file.

| Stage | What happens | Skill or command | Example prompt |
| --- | --- | --- | --- |
| Adopt the team | Install the files, then fill in project facts and tracker setup. | `script/adopt-agent-team.sh`, `script/init-agent-project.sh --labels` | Adopt the team into `~/projects/acme` and show me the facts I need to fill in. |
| Start a session | Talk to Elon, who routes the work. | `/elon` or `/ceo` | `/elon Help me choose the next objective.` |
| Intent | Record the user problem and wanted outcome for owner acceptance. | `/capture-intent` | `/capture-intent New users cannot tell whether setup is complete.` |
| Grill | Resolve open decisions; record terms and design choices. For owner blocked issues, record answers and relabel resolved issues `ready-for-agent`. | `/grill-with-docs`, `/grilling`, `/grill-backlog` | `/grill-backlog Ask me the decisions holding up the queue.` |
| Spec | Write a spec from an accepted intent, or publish the settled conversation as a tracker spec. | `/write-spec` for an intent file; `/to-spec` for a tracker spec | `/write-spec Use the accepted setup intent.` |
| Tickets | Split the accepted spec into small tickets with checks and blocking dependencies. | `/to-tickets` | `/to-tickets Split the accepted setup spec into buildable slices.` |
| Dispatch and build | Elon assigns work; workers build with tests first in their own worktrees and report results. | `/elon <objective>`, `/crew`, `orca orchestration worker-start`, `/tdd` | `/elon Deliver the ready setup tickets using /crew and /tdd.` |
| Review | Check the current diff against project rules and the ticket; add security review where needed. | `/code-review` | `/code-review Check this branch against main and its ticket.` |
| Merge | Elon pushes, opens the PR and merges after the required checks. Build and review workers never push or merge. | Ask Elon | Elon, merge the reviewed setup branch when its checks pass. |
| Deploy | Release-manager promotes through local, staging and production; production needs the owner's explicit go for that release. | `/deploy local`, `/deploy staging`, `/deploy production` | `/deploy staging Promote the commit that passed local checks.` |
| Status and daily run | Get company or engineering status, or run the project's daily checklist. | `/elon status`, `/elon daily run`, `/teddy status` | `/elon status Show Now, Needs owner and Running.` |
| Audit | Check team files for drift, contradictions and unused skills. | `/team-audit` | `/team-audit Check this repo's team files and propose fixes.` |
| Support | Elon routes fixes and support drafts the customer reply; the owner approves before sending or closing. | Ask Elon to assign `support-csm` | Elon, resolve this support ticket and bring me the reply draft for approval. |

## Skills

Reusable skills live in `.agents/skills/<name>/` and are visible to Claude Code, Codex, Cursor and Antigravity through individual links in `~/.agents/skills` and `~/.claude/skills` (also read by Cursor), and the Antigravity `skills.json`. A project skill with the same name as a central one silently wins, so keep the two sets apart:

| Kind | Lives in |
| --- | --- |
| Reusable across projects | here, `.agents/skills/<name>/`, and nowhere else |
| Project specific | `<project>/.agents/skills/<name>/`, with symlinks from `<project>/.claude/skills/` and `<project>/.cursor/skills/` |

Run `bash script/setup-agent-skills.sh` to migrate legacy tree links to real directories. It retains tool-installed skills and their lock data, leaves the old source intact, links only tracked dotfiles skills, and prints its actions. Existing tool folders and foreign links are preserved, including same-name conflicts. `DOTFILES_SKIP_SYSTEM_SETUP=1 bash install.sh` also performs this migration without installing software. The skill inventory requires a Git checkout.

Run `script/check-skill-collisions.sh` to find a project skill that shadows a central one, a broken symlink, or a missing `SKILL.md`. MCP secrets go in `~/.claude/settings.local.json` (gitignored). Paths reference: [AGENTS.md](../../AGENTS.md).

## Context, notes and backups

Project instructions (`AGENTS.md`) load always. Short cross-project rules live in `~/.claude/notes/` (`.agents/claude/notes/`) and the Obsidian vault holds deep docs. Add a lesson from any project:

```bash
~/dotfiles/script/contribute-to-agents.sh nextjs "Nested route-group layouts cause dev 404s"
```



```bash
bash script/backup-claude-desktop.sh   # Claude Desktop settings into init/
```
