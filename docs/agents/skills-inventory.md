# Skills inventory

Read only inventory of every skill the three agent teams use, so the copies can be deduplicated into `~/dotfiles`. Nothing was moved. Snapshot date 2026-10-06.

Short names used below:

| Name | Meaning |
| --- | --- |
| R | riben.life, `~/projects/riben.life`, read at `origin/main` 15c4bd633 (the local checkout is 2 commits behind) |
| P | PSTV, `~/pstv`, read at `origin/main` af650e2d6 (the local checkout is 3 commits behind) |
| T | dotfiles template, `templates/agent-team`, at dotfiles `master` c5f4251 |
| D | dotfiles shared tree, `.agents/skills/` at dotfiles `master`. Reached on the Mac as `~/.claude/skills`, `~/.agents/skills` and `~/.cursor/skills` (all three are home symlinks into this one tree, none of them hold their own copies) |
| MP | the `mattpocock-skills` plugin cache, v1.3.1 (upstream `6fd9479`, synced 2026-10-07), in two copies: `~/.claude/plugins/cache/mattpocock/...` (installed but disabled in `~/.claude/settings.json`, value `false`; skills load from the shared dotfiles folder D) and `~/.claude/plugins/cache/claude-plugins-official/...` (installed, not enabled) |
| dir | real directory, git tracked (mode 040000 tree) |
| link | symlink `../../.agents/skills/<name>`, git tracked (mode 120000) |

Sources scanned for references: `.claude/agents/*.md` (frontmatter `skills:` and body), `.claude/model-routing.md`, `AGENTS.md`, `docs/agents/team.md` (R only; P and T have none, T has `AGENTS.token-budget.md` instead of `AGENTS.md`), and every `.md` inside each team's own skills (skills that name other skills).

Slash commands named in those files that are not skills: `/compact`, `/clear`, `/btw`, `/fork`, `/subtask` (tool built ins) and `/unv`, `/join`, `/liff`, `/intent` (R app routes).

## Counts

| Measure | Count |
| --- | --- |
| Skills referenced by the teams | 27 |
| Skills inventoried (referenced plus unreferenced project skills found next to them) | 30 |
| Skills with two or more real copies | 23 (20 of them referenced) |
| Drifted (copies disagree in a way that is not just product facts) | 5: crew, tl, orchestration, elon/ceo, to-tickets (to-tickets also carries the local CONTEXT.md rename) |
| Referenced but not found anywhere | 0 |
| Referenced but not reachable for that team | 8 gaps over 7 names (see Missing) |
| Referenced skills absent in a fresh clone or cloud session | 17 for R, 16 for P |

## Inventory

Proposed home uses the three tiers the owner approved (Tier 1 general, Tier 2 team, Tier 3 project), defined under Migration plan.

| Skill | Referenced by | Copies and paths | Status | Proposed home |
| --- | --- | --- | --- | --- |
| agent-browser | qa-sdet (R, P, T), P stream-health | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| capture-intent | architect-pm (R, P, T) | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| code-review | elon, qa-sdet, secops-finops, tech-lead (R, P, T) | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). Shows twice in Claude Code (`code-review` and `mattpocock-skills:code-review`) only when the plugin is enabled. | Tier 1: dotfiles shared |
| codebase-design | architect-pm (R, P, T) | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| create-pr | fullstack-dev, tech-lead (R, P, T) | D dir | Single copy, but project aware: detects `web/` (R) or `pstv_web/` (P), riben `HOME.md` rule. | Tier 1: dotfiles shared; move the R and P branches into per repo config later |
| diagnosing-bugs | qa-sdet, support-csm (R, P, T), P stream-health | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| domain-modeling | architect-pm (R, P, T) | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| elon | elon role frontmatter and every role body (R, P, T); `AGENTS.md` (R, P); crew, tl, daily-run (R, P); P orchestration | D `elon/` dir | Drifted duplicate of `ceo`. `elon` is newer (2026-10-05 vs 2026-10-04) and adds the Commands section and direct dispatch wording. | Tier 2: dotfiles template, one copy (move out of D so it stops loading in every repo) |
| ceo | named only in elon's description ("or /ceo") | D `ceo/` dir | Older drifted copy of `elon` (`effort: max`, Tech Lead orchestrates). Both show in the skill list with the same description. | Tier 2: delete, or a 3 line stub next to `elon` that loads it |
| grill-with-docs | architect-pm (R, P, T) | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| orca-cli | model-routing (R, P, T); tl SKILL and other-tools (R, P); P orchestration | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| orchestration | elon role, `AGENTS.md`, crew SKILL, model-routing (R, P, T) | D `SKILL.md` only. P `.agents` dir with `SKILL.md` plus `worker-watch.sh` and `worker-watch.test.sh`, links in P `.claude` and `.cursor`. R `.agents` dir with the two scripts only, no `SKILL.md`, no `.claude` or `.cursor` link. T dir with the two scripts only. | Drifted. P `SKILL.md` is D plus one paragraph (Elon is the default coordinator), P newer (2026-10-05 vs 2026-09-29). The two scripts are byte identical in R, P and T. `check-skill-collisions.sh` reports FAIL: the R and P dirs shadow D, and R's dir has no `SKILL.md`. In R, Claude Code loads D's copy. | Tier 1: dotfiles shared; merge P's paragraph and both scripts into D, remove the R, P and T copies |
| research | architect-pm, sales-marketing, secops-finops (R, P, T), P stream-health | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| resolving-merge-conflicts | fullstack-dev (R, P, T) | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| tdd | elon, fullstack-dev, qa-sdet (R, P, T) | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| to-spec | elon (R, P, T) | D dir; MP twice | Matches MP 1.3.1 except the `CONTEXT.md` naming (see Mattpocock sync). | Tier 1: dotfiles shared |
| to-tickets | architect-pm, elon (R, P, T) | D dir; MP twice | Drifted. D adds two "Machine-checkable contract" sections (commit add20a3, 2026-10-04) with riben examples (`bun test --isolate`, `web/src/actions/foo`). D is newest. | Tier 1: dotfiles shared; replace the riben examples with neutral ones |
| write-spec | architect-pm (R, P, T) | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| crew | `AGENTS.md` (R); elon, tech-lead (R, P, T); tl SKILL (R, P) | R, P, T `.agents` dirs; links in R and P `.claude` and `.cursor` | Drifted, partly project specific. T vs R: 6 lines, T has the newer changelog fragment wording in Step 5, R has the `persistent-memory-protocol.md` pointer T lacks. R vs P: 125 lines, P rewrote it for the monorepo (absolute `/Users/mtsai/pstv` paths, component worktrees, CEO and BA in Step 1). Last commits: P 10-06 02:46, T 02:42, R 02:41. | Tier 2: dotfiles template, one project neutral copy; product facts move to a repo file the skill reads |
| tl | `AGENTS.md`, elon, tech-lead, daily-run (R, P); elon, tech-lead (T) | R, P `.agents` dirs; links in R and P `.claude` and `.cursor` | Drifted, 13 lines, partly project specific. P newer (2026-10-05 21:15 vs 14:27): adds the command suite line, `worker-start --agent` handoff wording, tiered routing rule; P only `issue-budget.md`. T ships no `tl`. | Tier 2: dotfiles template, one project neutral copy |
| deploy | `AGENTS.md`, release-manager, tech-lead, daily-run (R, P); R `team.md`; release-manager, tech-lead (T) | R, P `.agents` dirs; links in R and P `.claude` and `.cursor` | Project specific, not a dedupe target. R: stm36, Prisma migrate, Playground staging, ADR 0060. P: 5ik.tv, Jellyfin, stm38 and stm39. 106 lines apart. T ships no `deploy`. | Tier 2 per the owner decision, but it is mostly product facts: one generic deploy flow in the dotfiles template that reads hosts and steps from `docs/agents/deploy-facts.md` |
| roku-qa | its own SKILL (P) | P `.agents` dir; links in P `.claude` and `.cursor` | Project specific (Roku, 5ik, Jellyfin). | Tier 3: stays in P |
| action-scaffold | fullstack-dev (R, T); R store-admin-crud SKILL | R `.agents` dir and R `.cursor` dir, identical; R `.claude` link points at the `.cursor` copy | Duplicate inside R, identical. Project specific (Prisma, `web/src`, storeAdmin). | Tier 3: stays in R, one copy in `.agents`; drop from T |
| e2e-test-scaffold | fullstack-dev, qa-sdet (R, T); P qa-sdet body | R `.agents` and `.cursor` dirs, identical; R `.claude` link to `.cursor` | Duplicate inside R. Project specific. Not reachable for P or T. | Tier 3: stays in R; drop from P and T, or write a PSTV variant |
| i18n-sync | fullstack-dev (R, T) | as action-scaffold | Duplicate inside R, identical, project specific. | Tier 3: stays in R; drop from T |
| payment-plugin | fullstack-dev (R, T), including the Money and Payments rule | as action-scaffold | Duplicate inside R, identical, project specific. | Tier 3: stays in R; drop from T |
| store-admin-crud | fullstack-dev (R, T) | as action-scaffold | Duplicate inside R, identical, project specific. | Tier 3: stays in R; drop from T |
| shadcn | not referenced | R `.agents` and `.cursor` dirs, identical; R `.claude` link to `.cursor` | Duplicate inside R. Generic upstream shadcn skill, no riben facts. | Tier 1: dotfiles shared, or Tier 3 in R |
| jellyfin-web-port | not referenced (nested in P `web2/`) | P `web2/.agents` and `web2/.cursor` dirs, identical | Duplicate inside P, project specific. | Tier 3: stays in P; make the `.cursor` copy a link |
| paypal-webhooks | not referenced (nested in P `web2/`) | as jellyfin-web-port | Duplicate inside P, project specific. | Tier 3: stays in P; make the `.cursor` copy a link |

## Missing

Nothing is referenced that does not exist somewhere. These references cannot be reached by the team that makes them:

| Team | Skill | Why |
| --- | --- | --- |
| P | e2e-test-scaffold | P qa-sdet body names it; it lives only in R. (P dropped it from the frontmatter already.) |
| T | tl, deploy | Named in elon, tech-lead and release-manager frontmatter. T ships only crew and orchestration scripts, and `script/adopt-agent-team.sh` creates no `tl` or `deploy`. |
| T | action-scaffold, store-admin-crud, i18n-sync, payment-plugin, e2e-test-scaffold | riben skills leaked into T fullstack-dev and qa-sdet. An adopting project has none of them. |

## How the Mac links skills today

| Path | Points to | Made by |
| --- | --- | --- |
| `~/dotfiles` | `~/GitHub/dotfiles` | `install.sh` |
| `~/.agents` | `~/GitHub/dotfiles/.agents` | `install.sh` |
| `~/.claude/skills` | `~/dotfiles/.agents/skills` | `script/setup-claude-code.sh` |
| `~/.cursor/skills` | `~/dotfiles/.agents/skills` | `script/link-cursor-user.sh` (run by `setup-cursor.sh`, after `setup-claude-code.sh` deletes the link), so Cursor lists every shared skill twice. Fixed: see Duplicate listings. |
| Antigravity | `$AGENTS_ROOT/skills` via `~/.gemini/.../skills.json` | `script/setup-antigravity.sh` |
| `.agents/skills/synced/` | claude.ai synced skills, written through the home link into the dotfiles checkout | Claude Code; gitignored (`.gitignore` line 87) |

The `mattpocock-skills` plugin is installed but disabled (`false` in `~/.claude/settings.json`) while the same skills are vendored in D. Claude Code may still list a skill under both names if the plugin is switched on. D's `to-tickets` is locally edited, so D is the copy to keep.

## Fresh clones and cloud sessions

No committed skill symlink leaves its repo. All 22 tracked skill links (R 12, P 10) are relative `../../.agents/skills/<name>` or `../../.cursor/skills/<name>` and resolve in a fresh clone. The dotfiles repo has no tracked symlinks.

Tracked symlinks outside skills that do leave their repo and dangle in a clone (harmless for skills, listed for completeness):

| Repo | Link | Target |
| --- | --- | --- |
| R | `fileServer/backup/production/nginx/stm36.tvcdn.org/sites-enabled/` (4 links) | `/etc/nginx/sites-available/...` |
| P | `pstv_op/bin/linux/media_bin` | `/Volumes/data3/Media/bin/` |
| P | `pstv_op/bin/media/streamschedule.smil` | `/Users/mtsai/media/Movies/streamschedule.smil` |

The real cloud gap is the reverse: nothing in the repos points at dotfiles, so a cloud session (or any machine without `install.sh`) has no `~/.claude/skills` and no user plugins. Every role still preloads its frontmatter `skills:`, and these are absent:

* R (17): agent-browser, capture-intent, code-review, codebase-design, create-pr, diagnosing-bugs, domain-modeling, elon, grill-with-docs, orca-cli, orchestration, research, resolving-merge-conflicts, tdd, to-spec, to-tickets, write-spec.
* P (16): the same list without orchestration (P commits its own `SKILL.md`).

Both repos start every session as Elon (`"agent": "elon"` in `.claude/settings.json`), so a cloud session opens as a CEO whose own skill is missing.

## Migration plan

Layout decided by the owner on 2026-10-06 (option b: committed generated copies for tier 2). Three tiers:

| Tier | What | Lives | How a project sees it |
| --- | --- | --- | --- |
| 1 General | agent-browser, capture-intent, code-review, codebase-design, create-pr, diagnosing-bugs, domain-modeling, grill-with-docs, orca-cli, orchestration (with `worker-watch.sh`), research, resolving-merge-conflicts, tdd, to-spec, to-tickets, write-spec, the vendored mattpocock skills, optionally shadcn | `~/dotfiles/.agents/skills/<name>/` only | `~/.claude/skills` and `~/.agents/skills`, linked by `install.sh` (Cursor reads `~/.claude/skills`). No project copy, no project link. |
| 2 Team | elon, ceo (an alias that loads elon), crew, tl, deploy | Source: `~/dotfiles/templates/agent-team/.agents/skills/<name>/`, one product neutral copy each | A committed, generated copy in `<project>/.agents/skills/<name>/` plus committed relative links in `.claude/skills/` and `.cursor/skills/`, written by `~/dotfiles/script/sync-team-skills.sh`. Product facts live in the project's `docs/agents/team-facts.md` and `docs/agents/deploy-facts.md`. |
| 3 Project | R: action-scaffold, e2e-test-scaffold, i18n-sync, payment-plugin, store-admin-crud. P: roku-qa, web2 jellyfin-web-port, web2 paypal-webhooks | `<project>/.agents/skills/<name>/`, tracked | Tracked relative links `.claude/skills/<name>` and `.cursor/skills/<name>` to `../../.agents/skills/<name>`, which resolve in any clone |

Tier 2 is kept out of `~/dotfiles/.agents/skills` on purpose: that tree is linked as `~/.claude/skills`, so anything there loads in every repo on the Mac, not only in the team repos. Committed copies (rather than ignored links) mean a fresh clone, a cloud session and every Orca child worktree has the team skills without dotfiles.

### The sync script

`~/dotfiles/script/sync-team-skills.sh [--check] [--force] [<project-root> ...]` (default: the current directory).

* Sync copies every directory with a `SKILL.md` under `templates/agent-team/.agents/skills/` into `<project>/.agents/skills/<name>/`, replacing the whole directory, and makes `.claude/skills/<name>` and `.cursor/skills/<name>` relative links to it. A second run changes nothing.
* Each copied `SKILL.md` gets one line right after its frontmatter: `<!-- Generated from dotfiles templates/agent-team/.agents/skills/<name> by script/sync-team-skills.sh, do not edit. ... source-sha256: <hash> -->`. The hash covers every file path and content in the source skill, so it names the dotfiles version a copy came from.
* `--check` writes nothing and exits 1 when a copy is missing, a file differs (hand edited, or dotfiles moved on), a file is extra, or a link is missing. It prints the command that restores the copies.
* Sync refuses to replace a hand written skill directory (no stamp) or a real directory where a link belongs, so product facts are never wiped by accident. Move them out, then rerun with `--force`.
* It refuses the home folder, the dotfiles checkout, and any target whose `.agents/skills`, `.claude/skills` or `.cursor/skills` resolves outside it (as `~/.agents` does), so it can never write into the tier 1 tree.
* A generated skill that dotfiles no longer has is flagged by `--check` and removed by sync, with its links. Hand written project skills are never touched.
* `adopt-agent-team.sh` calls it, and writes the two facts skeletons from `templates/agent-team/docs/agents/` when they are missing.
* Test: `bash script/tests/sync-team-skills.test.sh`.

Run `--check` in each project's CI or pre-commit hook (phase 2) so a hand edit fails fast.

### Product facts files

Tier 2 skills hold no hosts, branches, ADR numbers or commands. They read:

| File | Read by | Holds |
| --- | --- | --- |
| `docs/agents/team-facts.md` | crew, tl | repository, extra `worker-start` flags, check commands, standards checklist, extra reviewers, changelog folder, terminal shortcut |
| `docs/agents/deploy-facts.md` | deploy | components, stage branches, status contexts, hosts, commands per stage, guards, production window, standing go, rollback |
| `docs/agents/daily-run.md` | elon (`/elon daily run`), tl other-tools | the daily run, moved out of `crew/daily-run.md` unchanged |
| `docs/agents/issue-budget.md` | tl, daily run | issue cap and filing rules (R has it already; P moves it out of `tl/issue-budget.md`) |

Skeletons for the first two: `templates/agent-team/docs/agents/`.

### Reconciled skills (phase 1, done in dotfiles)

| Skill | Result |
| --- | --- |
| crew | T base (changelog fragment wording, anti-fluttering, merge and queue draining steps) plus R's `persistent-memory-protocol.md` pointer plus P's newer Step 1 (BA writes ticket contracts, Tech Lead reviews the DAG), "Starting a worker" step and role default provider. Product facts moved to `team-facts.md`. `daily-run.md` leaves the skill. |
| tl | P's newer copy (command suite line, `worker-start --agent` wording); terminal shortcut from `team-facts.md`; `issue-budget.md` leaves the skill. `other-tools.md` is P's copy (tiered routing) with the daily run task count and the skills table made generic. |
| orchestration | Tier 1. D plus P's Elon coordinator paragraph, scoped to projects that have `.claude/agents/elon.md`. `worker-watch.sh` and its test move from the template into D; `model-routing.md` now calls `~/.claude/skills/orchestration/worker-watch.sh`. |
| elon, ceo | `elon` (newer) moves from D to the template, product names removed, daily run path now `docs/agents/daily-run.md`. `ceo` becomes a three line alias that loads `elon`. |
| to-tickets | D (newest) with neutral examples in place of the riben paths and `bun` commands. |
| deploy | One generic flow (rules, status, local, staging, production, hand deploy, rollback) that reads everything product specific from `deploy-facts.md`. |

### Duplicate listings

* `~/.cursor/skills`: `script/link-cursor-user.sh` (run by `setup-cursor.sh` after `setup-claude-code.sh`) recreated the link that `setup-claude-code.sh` had just removed. It no longer creates it.
* `mattpocock-skills` plugin: disabled in `.agents/claude/settings.json`. Its 12 skills dotfiles did not have yet (ask-matt, grill-me, handoff, implement, improve-codebase-architecture, prototype, teach, to-questionnaire, triage, wait-what, wayfinder, wizard) are vendored into `.agents/skills/` from plugin v1.2.3, commit `c55ee46073ed923f86ce59a5eb3b6d895095d1b7`. To refresh, copy the newer plugin skill folders over these and keep the local `to-tickets` edits.

### Steps, each with its check

1. Done (dotfiles, phase 1): tier 1 cleanup, tier 2 reconciliation, facts skeletons, sync script, duplicate fixes. Check: `bash script/tests/sync-team-skills.test.sh` passes; `grep -rn 'riben\|pstv\|/Users/' templates/agent-team/.agents/skills` finds nothing.
2. riben.life (phase 2): write `docs/agents/team-facts.md` and `docs/agents/deploy-facts.md`, `git mv .agents/skills/crew/daily-run.md docs/agents/daily-run.md`, `git rm -r .agents/skills/orchestration`, point `.claude/model-routing.md` at `~/.claude/skills/orchestration/worker-watch.sh`, run `sync-team-skills.sh --force .`, replace the six real `.cursor/skills` dirs of tier 3 skills with links to `.agents`, add `sync-team-skills.sh --check` to CI or pre-commit. Check: `--check` passes, `/elon`, `/crew`, `/tl`, `/deploy status` load and resolve their facts.
3. PSTV (phase 2): the same, plus `git mv .agents/skills/tl/issue-budget.md docs/agents/issue-budget.md` (and fix the path in daily run step 3), remove the orchestration `SKILL.md`, copy `docs/agents/persistent-memory-protocol.md` from the template, drop `e2e-test-scaffold` from qa-sdet or add a PSTV variant, turn `web2/.cursor/skills` copies into links. Check: same as step 2.

### Risks

| Risk | Level | Mitigation |
| --- | --- | --- |
| Cloud sessions and fresh clones have no `~/dotfiles`, so every tier 1 skill is absent (17 referenced skills for R, 16 for P). Tier 2 is covered by the committed copies. | High | dotfiles is public: the cloud environment setup (or a committed SessionStart hook) can run `git clone --depth 1 https://github.com/mingster/dotfiles ~/dotfiles && ~/dotfiles/install.sh` with `DOTFILES_SKIP_SYSTEM_SETUP=1`. Verify that skills linked by a hook are picked up in the same session; if not, it must run in environment setup. |
| A project copy drifts from dotfiles (someone edits it in place, or dotfiles moves on and nobody syncs). | Medium | The stamp tells editors not to; `--check` in each project's CI or pre-commit fails on any difference. |
| One tier 2 copy for two products means product facts must leave the skill. A missing fact breaks R or P deploys. | Medium | The facts files in the PR for this change list every value the old skills held; a dry run of `/deploy status` in both repos before deleting the old copies. |
| The first sync over a hand written project copy would wipe product files inside it (P `tl/issue-budget.md`, both `crew/daily-run.md`). | Medium | Sync refuses without `--force`; phase 2 moves those files first. |
| Tier 3 tracked relative links become plain text files on a Windows clone without `core.symlinks`. | Low | No Windows users today; the real dir in `.agents/skills` still works for Codex. |

## Mattpocock sync (2026-10-07)

Upstream `mattpocock/skills` at `6fd947921b935b7e1e69293a200400f0fdd5c15f` (plugin v1.3.1, was v1.2.3 at `c55ee46`). Pulled in `~/.claude/plugins/marketplaces/mattpocock` and `claude plugin update mattpocock-skills@mattpocock`. The plugin stays disabled at user scope; D is the copy every tool reads (`~/.agents/skills` and `~/.claude/skills` are both home symlinks into D, so Claude, Codex, Cursor and Antigravity load the same SKILL.md).

Local deviations from upstream, to re-apply on every refresh:

* Upstream renamed `CONTEXT.md` to `GLOSSARY.md` (and `CONTEXT-MAP.md`, `CONTEXT-FORMAT.md`). We keep `CONTEXT.md` everywhere (our AGENTS.md, `docs/SDLC.md` and `init-agent-project.sh` use it). After copying, run `sed -i '' 's/GLOSSARY/CONTEXT/g'` over the copied skills and rename `domain-modeling/GLOSSARY-FORMAT.md` to `CONTEXT-FORMAT.md`. `teach` keeps its own `GLOSSARY.md` because it is a separate teaching workspace file.
* `to-tickets` keeps the "Machine-checkable contract" sections (allowed files, verification command, blast radius) in both templates.

| Skill | Action | Reason |
| --- | --- | --- |
| ask-matt, domain-modeling, handoff, implement, setup-matt-pocock-skills, to-tickets | Updated | Newer upstream (to-tickets attaches tickets as sub-issues, implement calls the Skill tool, handoff resolves the temp dir, ask-matt lists `/implement-spec`, `/pr`, `/retro`). |
| tdd, diagnosing-bugs, codebase-design, improve-codebase-architecture, triage, wait-what, to-spec, code-review, grill-with-docs, grilling, research, prototype, wizard, wayfinder, grill-me, teach, to-questionnaire, writing-for-agents, resolving-merge-conflicts | Unchanged | Identical to upstream apart from the `CONTEXT.md` naming. |
| retro | Added | Looks back over a session and suggests environment changes (docs, hooks, navigation), which fits the daily-run learning loop. |
| implement-spec | Skipped | Runs implementer subagents in parallel inside the harness; our rule is Orca workers, never Claude subagents. |
| pr | Skipped | Writes a PR body template that conflicts with `create-pr` and the owner's PR body rules (no Test plan, no tool mention). |
| chief-of-staff, claude-handoff, loop-me, setup-ts-deep-modules, writing-beats, writing-fragments, writing-shape | Skipped | Upstream `in-progress`, unstable, off workflow. |
| git-guardrails-claude-code, migrate-to-shoehorn, scaffold-exercises, setup-pre-commit | Skipped | Upstream `misc`; guardrails and pre-commit are covered by our hooks, the others are TypeScript course tooling. |

The fast path names (`to-spec`, `to-tickets`, `tdd`, `code-review`) and `diagnosing-bugs`, `grill-with-docs`, `research` are unchanged upstream, and none of the role files, elon/tl/crew skills or `docs/agents/*.md` pass arguments to them, so the team docs needed no edit in R, P or T.

`script/init-agent-project.sh` seeds `docs/agents/{issue-tracker,triage-labels,domain}.md` from `setup-matt-pocock-skills`. It now accepts a git worktree (`.git` as a file) and the GitHub seed gained the sub-issue operation that the new `to-tickets` uses. R already had the three files (a sub-issue line was added to R's `issue-tracker.md`); P had none and was seeded.
