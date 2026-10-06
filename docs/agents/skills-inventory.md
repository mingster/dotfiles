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

| Skill | Referenced by | Copies and paths | Status | Proposed home |
| --- | --- | --- | --- | --- |
| agent-browser | qa-sdet (R, P, T), P stream-health | D dir | Single copy. Absent in cloud. | dotfiles shared |
| capture-intent | architect-pm (R, P, T) | D dir | Single copy. Absent in cloud. | dotfiles shared |
| code-review | elon, qa-sdet, secops-finops, tech-lead (R, P, T) | D dir; MP twice | Identical to MP. Shows twice in Claude Code (`code-review` and `mattpocock-skills:code-review`). | dotfiles shared |
| codebase-design | architect-pm (R, P, T) | D dir; MP twice | Identical to MP. | dotfiles shared |
| create-pr | fullstack-dev, tech-lead (R, P, T) | D dir | Single copy, but project aware: detects `web/` (R) or `pstv_web/` (P), riben `HOME.md` rule. | dotfiles shared; move the R and P branches into per repo config later |
| diagnosing-bugs | qa-sdet, support-csm (R, P, T), P stream-health | D dir; MP twice | Identical to MP. | dotfiles shared |
| domain-modeling | architect-pm (R, P, T) | D dir; MP twice | Identical to MP. | dotfiles shared |
| elon | elon role frontmatter and every role body (R, P, T); `AGENTS.md` (R, P); crew, tl, daily-run (R, P); P orchestration | D `elon/` dir | Drifted duplicate of `ceo`. `elon` is newer (2026-10-05 vs 2026-10-04) and adds the Commands section and direct dispatch wording. | dotfiles shared, one copy |
| ceo | named only in elon's description ("or /ceo") | D `ceo/` dir | Older drifted copy of `elon` (`effort: max`, Tech Lead orchestrates). Both show in the skill list with the same description. | dotfiles shared as a 3 line stub that loads `elon`, or delete it |
| grill-with-docs | architect-pm (R, P, T) | D dir; MP twice | Identical to MP. | dotfiles shared |
| orca-cli | model-routing (R, P, T); tl SKILL and other-tools (R, P); P orchestration | D dir | Single copy. Absent in cloud. | dotfiles shared |
| orchestration | elon role, `AGENTS.md`, crew SKILL, model-routing (R, P, T) | D `SKILL.md` only. P `.agents` dir with `SKILL.md` plus `worker-watch.sh` and `worker-watch.test.sh`, links in P `.claude` and `.cursor`. R `.agents` dir with the two scripts only, no `SKILL.md`, no `.claude` or `.cursor` link. T dir with the two scripts only. | Drifted. P `SKILL.md` is D plus one paragraph (Elon is the default coordinator), P newer (2026-10-05 vs 2026-09-29). The two scripts are byte identical in R, P and T. `check-skill-collisions.sh` reports FAIL: the R and P dirs shadow D, and R's dir has no `SKILL.md`. In R, Claude Code loads D's copy. | dotfiles shared: merge P's paragraph and both scripts into D |
| research | architect-pm, sales-marketing, secops-finops (R, P, T), P stream-health | D dir; MP twice | Identical to MP. | dotfiles shared |
| resolving-merge-conflicts | fullstack-dev (R, P, T) | D dir; MP twice | Identical to MP. | dotfiles shared |
| tdd | elon, fullstack-dev, qa-sdet (R, P, T) | D dir; MP twice | Identical to MP. | dotfiles shared |
| to-spec | elon (R, P, T) | D dir; MP twice | Identical to MP. | dotfiles shared |
| to-tickets | architect-pm, elon (R, P, T) | D dir; MP twice | Drifted. D adds two "Machine-checkable contract" sections (commit add20a3, 2026-10-04) with riben examples (`bun test --isolate`, `web/src/actions/foo`). D is newest. | dotfiles shared; replace the riben examples with neutral ones |
| write-spec | architect-pm (R, P, T) | D dir | Single copy. Absent in cloud. | dotfiles shared |
| crew | `AGENTS.md` (R); elon, tech-lead (R, P, T); tl SKILL (R, P) | R, P, T `.agents` dirs; links in R and P `.claude` and `.cursor` | Drifted, partly project specific. T vs R: 6 lines, T has the newer changelog fragment wording in Step 5, R has the `persistent-memory-protocol.md` pointer T lacks. R vs P: 125 lines, P rewrote it for the monorepo (absolute `/Users/mtsai/pstv` paths, component worktrees, CEO and BA in Step 1). Last commits: P 10-06 02:46, T 02:42, R 02:41. | dotfiles template (generic base); rendered copy stays in each project |
| tl | `AGENTS.md`, elon, tech-lead, daily-run (R, P); elon, tech-lead (T) | R, P `.agents` dirs; links in R and P `.claude` and `.cursor` | Drifted, 13 lines, partly project specific. P newer (2026-10-05 21:15 vs 14:27): adds the command suite line, `worker-start --agent` handoff wording, tiered routing rule; P only `issue-budget.md`. T ships no `tl`. | dotfiles template base; project copy stays |
| deploy | `AGENTS.md`, release-manager, tech-lead, daily-run (R, P); R `team.md`; release-manager, tech-lead (T) | R, P `.agents` dirs; links in R and P `.claude` and `.cursor` | Project specific, not a dedupe target. R: stm36, Prisma migrate, Playground staging, ADR 0060. P: 5ik.tv, Jellyfin, stm38 and stm39. 106 lines apart. T ships no `deploy`. | stays in project; template ships a skeleton |
| roku-qa | its own SKILL (P) | P `.agents` dir; links in P `.claude` and `.cursor` | Project specific (Roku, 5ik, Jellyfin). | stays in P |
| action-scaffold | fullstack-dev (R, T); R store-admin-crud SKILL | R `.agents` dir and R `.cursor` dir, identical; R `.claude` link points at the `.cursor` copy | Duplicate inside R, identical. Project specific (Prisma, `web/src`, storeAdmin). | stays in R, one copy in `.agents`; drop from T |
| e2e-test-scaffold | fullstack-dev, qa-sdet (R, T); P qa-sdet body | R `.agents` and `.cursor` dirs, identical; R `.claude` link to `.cursor` | Duplicate inside R. Project specific. Not reachable for P or T. | stays in R; drop from P and T, or write a PSTV variant |
| i18n-sync | fullstack-dev (R, T) | as action-scaffold | Duplicate inside R, identical, project specific. | stays in R; drop from T |
| payment-plugin | fullstack-dev (R, T), including the Money and Payments rule | as action-scaffold | Duplicate inside R, identical, project specific. | stays in R; drop from T |
| store-admin-crud | fullstack-dev (R, T) | as action-scaffold | Duplicate inside R, identical, project specific. | stays in R; drop from T |
| shadcn | not referenced | R `.agents` and `.cursor` dirs, identical; R `.claude` link to `.cursor` | Duplicate inside R. Generic upstream shadcn skill, no riben facts. | dotfiles shared, or leave in R |
| jellyfin-web-port | not referenced (nested in P `web2/`) | P `web2/.agents` and `web2/.cursor` dirs, identical | Duplicate inside P, project specific. | stays in P; make the `.cursor` copy a link |
| paypal-webhooks | not referenced (nested in P `web2/`) | as jellyfin-web-port | Duplicate inside P, project specific. | stays in P; make the `.cursor` copy a link |

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

### Proposed layout

```text
~/dotfiles (repo, source of truth)
  .agents/skills/<shared>/                 real dirs: the 17 shared skills above, plus shadcn
  .agents/skills/orchestration/            SKILL.md (with P's Elon paragraph) + worker-watch.sh + worker-watch.test.sh
  .agents/skills/ceo/                      stub that says "load elon", or removed
  templates/agent-team/.agents/skills/
    crew/  tl/  deploy/                    generic bases with {{PROJECT_NAME}}; deploy is a skeleton
  script/sync-team-skills.sh               new: copies the team core set into a project and writes the lock

~ (per machine, made by install.sh, unchanged except one line)
  ~/.claude/skills -> ~/dotfiles/.agents/skills
  ~/.agents        -> ~/dotfiles/.agents
  ~/.cursor/skills                         removed (Cursor already reads ~/.claude/skills)

<project> (riben.life, pstv, any adopter)
  .agents/skills/<name>/                   real dirs, tracked: project skills + vendored team core
  skills-lock.json                         source repo, path and hash per vendored skill (P already has this file for orchestration)
  .claude/skills/<name> -> ../../.agents/skills/<name>    tracked link
  .cursor/skills/<name> -> ../../.agents/skills/<name>    tracked link
```

Team core set to vendor (the union of role frontmatter `skills:`): elon, orchestration, tdd, code-review, diagnosing-bugs, agent-browser, create-pr, capture-intent, write-spec, to-tickets, research, plus the project's own crew, tl and deploy. Secondary skills stay user level only.

Rule: never commit a link to `~/dotfiles`, `~/.claude` or any absolute path. Vendored files are real copies.

### Steps, each with its check

1. dotfiles: merge P's orchestration paragraph and the two scripts into D; drop the script copy from T and point `adopt-agent-team.sh` at D. Check: the three script copies hash equal to D.
2. dotfiles: turn `ceo` into a stub, fix the riben examples in `to-tickets`, disable the user scope `mattpocock-skills` plugin. Check: each skill appears once in the Claude Code skill list.
3. dotfiles template: add `tl` and a `deploy` skeleton, remove the five riben skill names from T fullstack-dev and qa-sdet, have `adopt-agent-team.sh` link `tl` and `deploy`. Check: every frontmatter skill in T resolves inside T or the core set.
4. Add `script/sync-team-skills.sh` and teach `check-skill-collisions.sh` to accept a project copy whose hash matches `skills-lock.json` (today any project copy of a D skill is a FAIL). Check: the collision script passes on R and P after a sync.
5. riben.life: replace the six real `.cursor/skills` dirs with links to `.agents`, run the sync, link `orchestration` from `.claude/skills`. Check: `git ls-files -s .cursor/skills .claude/skills` shows only mode 120000.
6. PSTV: remove `e2e-test-scaffold` from qa-sdet (or add a PSTV variant), turn the `web2/.cursor/skills` copies into links, run the sync. Check: same `ls-files` check, and a fresh clone lists every role's frontmatter skill.

### Risks

| Risk | Where | Level | Mitigation |
| --- | --- | --- | --- |
| Cloud and fresh clones miss 16 or 17 shared skills | today | High | Vendor the core set into each repo (steps 4 to 6). |
| Vendored copies drift from dotfiles | after migration | Medium | Lock file with hashes, collision script in CI or a pre push hook. |
| A stale project copy shadows a fixed dotfiles copy on the Mac (project skills win) | after migration | Medium | Re sync before release; the collision script flags hash mismatches. |
| Relative links become plain text files on Windows clones without `core.symlinks` | after migration | Low | No Windows users today; vendored real dirs in `.agents/skills` still work for Codex. |
| Alternative: publish dotfiles as a plugin marketplace (repo is public) and enable it in each repo's `.claude/settings.json` | not chosen | Medium | Avoids copies, but plugin skills are namespaced (`dotfiles:tdd`), so role frontmatter `skills: [tdd]` may not resolve, and Codex and Cursor do not read Claude plugins. Verify before choosing it. |
