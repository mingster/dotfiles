# Skills inventory

Read only inventory of every skill the three agent teams use, so the copies can be deduplicated into `~/dotfiles`. Nothing was moved. Snapshot date 2026-10-06.

Short names used below:

| Name | Meaning |
| --- | --- |
| R | riben.life, `~/projects/riben.life`, read at `origin/main` 15c4bd633 (the local checkout is 2 commits behind) |
| P | PSTV, `~/pstv`, read at `origin/main` af650e2d6 (the local checkout is 3 commits behind) |
| T | dotfiles template, `templates/agent-team`, at dotfiles `master` c5f4251 |
| D | dotfiles shared tree, `.agents/skills/` at dotfiles `master`. Reached on the Mac as `~/.claude/skills`, `~/.agents/skills` and `~/.cursor/skills` (all three are home symlinks into this one tree, none of them hold their own copies) |
| MP | the `mattpocock-skills` plugin cache, v1.2.3, in two copies: `~/.claude/plugins/cache/mattpocock/...` (enabled in `~/.claude/settings.json`) and `~/.claude/plugins/cache/claude-plugins-official/...` (installed, not enabled) |
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
| Drifted (copies disagree in a way that is not just product facts) | 5: crew, tl, orchestration, elon/ceo, to-tickets |
| Referenced but not found anywhere | 0 |
| Referenced but not reachable for that team | 8 gaps over 7 names (see Missing) |
| Referenced skills absent in a fresh clone or cloud session | 17 for R, 16 for P |

## Inventory

Proposed home uses the three tiers the owner approved (Tier 1 general, Tier 2 team, Tier 3 project), defined under Migration plan.

| Skill | Referenced by | Copies and paths | Status | Proposed home |
| --- | --- | --- | --- | --- |
| agent-browser | qa-sdet (R, P, T), P stream-health | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| capture-intent | architect-pm (R, P, T) | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| code-review | elon, qa-sdet, secops-finops, tech-lead (R, P, T) | D dir; MP twice | Identical to MP. Shows twice in Claude Code (`code-review` and `mattpocock-skills:code-review`). | Tier 1: dotfiles shared |
| codebase-design | architect-pm (R, P, T) | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| create-pr | fullstack-dev, tech-lead (R, P, T) | D dir | Single copy, but project aware: detects `web/` (R) or `pstv_web/` (P), riben `HOME.md` rule. | Tier 1: dotfiles shared; move the R and P branches into per repo config later |
| diagnosing-bugs | qa-sdet, support-csm (R, P, T), P stream-health | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| domain-modeling | architect-pm (R, P, T) | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| elon | elon role frontmatter and every role body (R, P, T); `AGENTS.md` (R, P); crew, tl, daily-run (R, P); P orchestration | D `elon/` dir | Drifted duplicate of `ceo`. `elon` is newer (2026-10-05 vs 2026-10-04) and adds the Commands section and direct dispatch wording. | Tier 2: dotfiles template, one copy (move out of D so it stops loading in every repo) |
| ceo | named only in elon's description ("or /ceo") | D `ceo/` dir | Older drifted copy of `elon` (`effort: max`, Tech Lead orchestrates). Both show in the skill list with the same description. | Tier 2: delete, or a 3 line stub next to `elon` that loads it |
| grill-with-docs | architect-pm (R, P, T) | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| orca-cli | model-routing (R, P, T); tl SKILL and other-tools (R, P); P orchestration | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| orchestration | elon role, `AGENTS.md`, crew SKILL, model-routing (R, P, T) | D `SKILL.md` only. P `.agents` dir with `SKILL.md` plus `worker-watch.sh` and `worker-watch.test.sh`, links in P `.claude` and `.cursor`. R `.agents` dir with the two scripts only, no `SKILL.md`, no `.claude` or `.cursor` link. T dir with the two scripts only. | Drifted. P `SKILL.md` is D plus one paragraph (Elon is the default coordinator), P newer (2026-10-05 vs 2026-09-29). The two scripts are byte identical in R, P and T. `check-skill-collisions.sh` reports FAIL: the R and P dirs shadow D, and R's dir has no `SKILL.md`. In R, Claude Code loads D's copy. | Tier 1: dotfiles shared; merge P's paragraph and both scripts into D, remove the R, P and T copies |
| research | architect-pm, sales-marketing, secops-finops (R, P, T), P stream-health | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| resolving-merge-conflicts | fullstack-dev (R, P, T) | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| tdd | elon, fullstack-dev, qa-sdet (R, P, T) | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| to-spec | elon (R, P, T) | D dir; MP twice | Identical to MP. | Tier 1: dotfiles shared |
| to-tickets | architect-pm, elon (R, P, T) | D dir; MP twice | Drifted. D adds two "Machine-checkable contract" sections (commit add20a3, 2026-10-04) with riben examples (`bun test --isolate`, `web/src/actions/foo`). D is newest. | Tier 1: dotfiles shared; replace the riben examples with neutral ones |
| write-spec | architect-pm (R, P, T) | D dir | Single copy. Absent in cloud. | Tier 1: dotfiles shared |
| crew | `AGENTS.md` (R); elon, tech-lead (R, P, T); tl SKILL (R, P) | R, P, T `.agents` dirs; links in R and P `.claude` and `.cursor` | Drifted, partly project specific. T vs R: 6 lines, T has the newer changelog fragment wording in Step 5, R has the `persistent-memory-protocol.md` pointer T lacks. R vs P: 125 lines, P rewrote it for the monorepo (absolute `/Users/mtsai/pstv` paths, component worktrees, CEO and BA in Step 1). Last commits: P 10-06 02:46, T 02:42, R 02:41. | Tier 2: dotfiles template, one project neutral copy; product facts move to a repo file the skill reads |
| tl | `AGENTS.md`, elon, tech-lead, daily-run (R, P); elon, tech-lead (T) | R, P `.agents` dirs; links in R and P `.claude` and `.cursor` | Drifted, 13 lines, partly project specific. P newer (2026-10-05 21:15 vs 14:27): adds the command suite line, `worker-start --agent` handoff wording, tiered routing rule; P only `issue-budget.md`. T ships no `tl`. | Tier 2: dotfiles template, one project neutral copy |
| deploy | `AGENTS.md`, release-manager, tech-lead, daily-run (R, P); R `team.md`; release-manager, tech-lead (T) | R, P `.agents` dirs; links in R and P `.claude` and `.cursor` | Project specific, not a dedupe target. R: stm36, Prisma migrate, Playground staging, ADR 0060. P: 5ik.tv, Jellyfin, stm38 and stm39. 106 lines apart. T ships no `deploy`. | Tier 2 per the owner decision, but it is mostly product facts: one generic deploy flow in the dotfiles template that reads hosts and steps from a repo file (for example `docs/agents/deploy.md`) |
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
| `~/.cursor/skills` | `~/dotfiles/.agents/skills` | unknown. `setup-claude-code.sh` deletes this link when it resolves to the same tree as `~/.claude/skills`, but it was recreated on 2026-10-05, so Cursor lists every shared skill twice. |
| Antigravity | `$AGENTS_ROOT/skills` via `~/.gemini/.../skills.json` | `script/setup-antigravity.sh` |
| `.agents/skills/synced/` | claude.ai synced skills, written through the home link into the dotfiles checkout | Claude Code; gitignored (`.gitignore` line 87) |

The `mattpocock-skills` plugin is enabled at user scope while the same skills are vendored in D, so Claude Code offers each one twice. D's `to-tickets` is locally edited, so D is the copy to keep.

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

Layout approved by the owner on 2026-10-06. Three tiers:

| Tier | What | Lives | How a project sees it |
| --- | --- | --- | --- |
| 1 General | agent-browser, capture-intent, code-review, codebase-design, create-pr, diagnosing-bugs, domain-modeling, grill-with-docs, orca-cli, orchestration (with `worker-watch.sh`), research, resolving-merge-conflicts, tdd, to-spec, to-tickets, write-spec, optionally shadcn | `~/dotfiles/.agents/skills/<name>/` only | `~/.claude/skills` and `~/.agents/skills`, linked by `install.sh`. No project copy, no project link. |
| 2 Team | elon (ceo stub or removed), crew, tl, deploy | `~/dotfiles/templates/agent-team/.agents/skills/<name>/` only, one project neutral copy each | Git ignored symlinks in each project, made by `~/dotfiles/script/link-team-skills.sh` |
| 3 Project | R: action-scaffold, e2e-test-scaffold, i18n-sync, payment-plugin, store-admin-crud. P: roku-qa, web2 jellyfin-web-port, web2 paypal-webhooks | `<project>/.agents/skills/<name>/`, tracked | Tracked relative links `.claude/skills/<name>` and `.cursor/skills/<name>` to `../../.agents/skills/<name>`, which resolve in any clone |

Tier 2 is kept out of `~/dotfiles/.agents/skills` on purpose: that tree is linked as `~/.claude/skills`, so anything there loads in every repo on the Mac, not only in the two team repos.

### Proposed symlink layout

```text
~/dotfiles (repo, single source)
  .agents/skills/<tier 1>/                         real dirs
  .agents/skills/orchestration/                    SKILL.md (with P's Elon paragraph) + worker-watch.sh + worker-watch.test.sh
  templates/agent-team/.agents/skills/
    elon/  crew/  tl/  deploy/                     real dirs, tier 2, no {{PROJECT_NAME}} placeholders
  script/link-team-skills.sh                       new, idempotent

~ (per machine, install.sh)
  ~/.claude/skills -> ~/dotfiles/.agents/skills    unchanged
  ~/.agents        -> ~/dotfiles/.agents           unchanged
  ~/.cursor/skills                                 removed (Cursor already reads ~/.claude/skills)

<project> (riben.life, pstv, any adopter)
  .agents/skills/<tier 3>/                         real dirs, tracked
  .claude/skills/<tier 3> -> ../../.agents/skills/<tier 3>     tracked link
  .cursor/skills/<tier 3> -> ../../.agents/skills/<tier 3>     tracked link
  .agents/skills/<tier 2> -> ~/dotfiles/templates/agent-team/.agents/skills/<tier 2>   ignored link
  .claude/skills/<tier 2> -> same target                       ignored link
  .cursor/skills/<tier 2> -> same target                       ignored link
  .gitignore                                       one line per tier 2 link, written by the script
```

`script/link-team-skills.sh [project-root ...]` creates the three links per tier 2 skill, adds each path to the project's `.gitignore` if missing, refuses to replace a real dir or a tracked path (prints the `git rm` to run instead), and exits non zero when `~/dotfiles` is missing. `adopt-agent-team.sh` calls it instead of copying crew and the orchestration scripts.

### Steps, each with its check

1. Tier 1, dotfiles: merge P's orchestration paragraph and both scripts into D. Change the `worker-watch.sh` path in the three `model-routing.md` files and `adopt-agent-team.sh` from `.agents/skills/orchestration/` to `~/.claude/skills/orchestration/`. Check: `grep -r worker-watch` finds no repo relative path.
2. Tier 1, dotfiles: fix the riben examples in `to-tickets`, disable the user scope `mattpocock-skills` plugin, remove `~/.cursor/skills`. Check: each skill appears once in the Claude Code and Cursor skill lists.
3. Tier 2, dotfiles: move `elon` from D to the template tree, delete `ceo` or leave a stub there. Merge crew and tl into one project neutral copy each (newest wording from the Inventory rows; P's monorepo paths and R's `bun` commands move into each repo's `AGENTS.md` or a `docs/agents/` file the skill names). Write one generic `deploy` that reads its hosts and steps from a repo file. Remove the five riben skill names from T fullstack-dev and qa-sdet. Check: no tier 2 file contains `riben`, `pstv`, a host name or an absolute path.
4. Add `script/link-team-skills.sh`; update `check-skill-collisions.sh` so a tier 2 ignored link is expected and any project copy of a tier 1 skill stays a FAIL. Check: the script is idempotent (second run changes nothing) and passes `bash script/shellcheck-dotfiles.sh`.
5. riben.life: `git rm` the tracked `.agents/skills/{crew,tl,deploy,orchestration}` dirs and their `.claude` and `.cursor` links, replace the six real `.cursor/skills` dirs with links to `.agents`, run the link script. Check: `git ls-files -s .claude/skills .cursor/skills` shows only tier 3 names at mode 120000, and `/elon`, `/crew`, `/tl`, `/deploy` still load.
6. PSTV: same removals (including its orchestration `SKILL.md` and `skills-lock.json` entry), drop `e2e-test-scaffold` from qa-sdet or add a PSTV variant, turn `web2/.cursor/skills` copies into links, run the link script. Check: same as step 5.

### Risks

| Risk | Level | Mitigation |
| --- | --- | --- |
| Cloud sessions and fresh clones have no `~/dotfiles`, so every tier 1 and tier 2 skill is absent (17 referenced skills for R, 16 for P today, plus crew, tl and deploy after step 5 removes the tracked copies). Both repos start every session as Elon, so a cloud session opens with no `elon` skill. | High | dotfiles is public: the cloud environment setup (or a committed SessionStart hook) can run `git clone --depth 1 https://github.com/mingster/dotfiles ~/dotfiles && ~/dotfiles/install.sh` with `DOTFILES_SKIP_SYSTEM_SETUP=1`, then `link-team-skills.sh`. Verify that skills linked by a hook are picked up in the same session; if not, it must run in environment setup. |
| Git ignored links do not exist in new git worktrees. Crew dispatches every worker with `--worktree new-child`, so workers lose crew, tl and deploy (tier 1 is fine, it comes from home). | High | Run `link-team-skills.sh` in the worktree create path: an Orca worktree setup hook (neither repo has `orca.yaml` yet) or a SessionStart hook. Workers mostly need tier 1, so the gap mainly hits release-manager (`deploy`) and tech-lead (`tl`, `crew`). |
| Ignored links are absolute (`/Users/mtsai/dotfiles/...`), so a machine with a different home or no dotfiles gets dangling links. | Medium | The links are never committed, so they only exist where the script ran; the script exits non zero when `~/dotfiles` is missing. |
| One tier 2 copy for two products means product facts must leave the skill. Missing that move breaks R or P deploys. | Medium | Step 3 check (no product names or hosts in tier 2), then a dry run of `/deploy` status in both repos before removing the tracked copies. |
| Codex reads `.agents/skills` and `~/.agents/skills`, Cursor reads `.cursor/skills` and `~/.claude/skills`; a tier 2 skill reached only through one tool's folder is invisible to the others. | Low | The script links all three project folders. |
| Tier 3 tracked relative links become plain text files on a Windows clone without `core.symlinks`. | Low | No Windows users today; the real dir in `.agents/skills` still works for Codex. |
