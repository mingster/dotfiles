# Spec: team role files live only in dotfiles

**Owner decision (2026-11-08):** Each Mingster team role exists once in dotfiles. Projects (`riben.life`, `pstv`, others) must not keep copies under `.claude/agents/`.

**Roles in scope:** `elon`, `architect-pm`, `fullstack-dev`, `qa-sdet`, `release-manager`, `sales-marketing`, `secops-finops`, `support-csm`.

---

## 1. Canonical location and how Claude Code loads roles

### Where the unique files live

| Layer | Path | Content |
| --- | --- | --- |
| **Canonical source (git)** | `~/dotfiles/templates/agent-team/.claude/agents/<role>.md` | Eight team roles; no `{{PROJECT_NAME}}` or other per-project placeholders. |
| **User-level discovery (machine)** | `~/.claude/agents/<role>.md` | Symlinks installed by `script/setup-claude-code.sh`, one per team role → canonical source. Laravel-only agents (`laravel-*`) stay as today under `~/dotfiles/.agents/claude/agents/` and are linked the same way. |
| **Forbidden in projects** | `<project>/.claude/agents/<team-role>.md` | Must not exist after migration (see §5). Project-only *custom* roles are out of scope until the owner defines a separate pattern. |

### Claude Code behavior (verified)

Per [Subagents](https://code.claude.com/docs/en/sub-agents) (2026):

- **Project** `.claude/agents/` — discovered walking up from cwd; precedence over user when the same `name` is defined closer to the working directory.
- **User** `~/.claude/agents/` — available in every project; lower precedence than a project file with the same `name`.
- `claude --agent <name>` and the `agent` setting in `.claude/settings.json` resolve definitions from both trees (plus plugins / managed settings).
- New `~/.claude/agents/` directories may require a session restart; symlinks created by `setup-claude-code.sh` should exist before workers start.

**Implication:** team roles must load from `~/.claude/agents/` only. Any leftover `<project>/.claude/agents/elon.md` (etc.) **shadows** the dotfiles copy and violates the owner rule.

### Non–Claude Code workers (Cursor, Antigravity, Orca)

Keep today’s rule: the worker spec names an **absolute path** to the canonical file, not the project tree:

```text
Read ~/dotfiles/templates/agent-team/.claude/agents/<role>.md first and follow it.
```

Update `templates/agent-team/.claude/model-routing.md` accordingly (drop “main checkout’s `.claude/agents/`”).

### `setup-claude-code.sh` change (dotfiles PR, not this draft)

After linking `~/dotfiles/.agents/claude/` into `~/.claude/`, also ensure `~/.claude/agents/` exists and contains symlinks:

```text
elon.md -> ~/dotfiles/templates/agent-team/.claude/agents/elon.md
… (all eight team roles)
```

Re-run `install.sh` or `setup-claude-code.sh` on every fleet host after merge.

---

## 2. Project-specific facts (no placeholders in role files)

Role files hold **shared** behaviour only. Per-repo facts live in project-owned docs; roles **point** with stable paths (no templating).

| Fact type | Project-owned file | How the role references it |
| --- | --- | --- |
| Repo, PR target, lint/test commands, review checklist, changelog layout, Orca flags | `docs/agents/team-facts.md` | “Read `docs/agents/team-facts.md` (Repository, Checks, Review, …).” |
| Hosts, deploy commands, production gate, RM host | `docs/agents/deploy-facts.md` | Same pattern; `release-manager` and `deploy` skill already expect this. |
| Daily run time, digest SQL, DB URL | `docs/agents/team-facts.md` § Daily run | `daily-run.md` / `elon` daily path. |
| Customer-facing language for support | `docs/agents/team-facts.md` or ADR | `support-csm`, `elon` support queue. |
| Display name / marketing name | `docs/agents/team-facts.md` § Product | Replaces `{{PROJECT_NAME}}` in descriptions. |
| Shared process depth (not product-specific) | `~/dotfiles/templates/agent-team/docs/agents/*.md` | Unchanged (`architect-pm-work.md`, `elon-dispatch.md`, `team.md`, etc.). |

**Role frontmatter `description`:** use role title + “for the active project”; require reading `docs/agents/team-facts.md` § Product for the commercial name.

**Skills:** tier-2 team skills stay generated under `<project>/.agents/skills/` via `sync-team-skills.sh`; they already read project facts from `docs/agents/` (unchanged).

---

## 3. Touch points: templates, scripts, hooks, gates

Grep target: `.claude/agents` under `~/dotfiles` (92 lines / 34 paths, 2026-11-08).

### Template tree (`templates/agent-team/`)

| Path | Change |
| --- | --- |
| `.claude/agents/*.md` | Strip `{{PROJECT_NAME}}`; add pointers to `docs/agents/team-facts.md`. Canonical only. |
| `docs/agents/team.md` | State roles live in dotfiles + `~/.claude/agents/`; projects hold facts only. |
| `docs/agents/team-facts.md` | Remove “worker worktrees hold `.claude/agents/`”; add Product section. |
| `docs/agents/engineering-integration.md`, `daily-run.md` | Paths → `~/dotfiles/templates/agent-team/.claude/agents/` or “user agent dir”. |
| `.claude/model-routing.md` | Worker spec absolute path → dotfiles canonical; drop “project must have `.claude/agents`”. |
| `.claude/settings.json` | Post-compact echo: `.claude/agents/<role>.md` → `~/dotfiles/templates/agent-team/.claude/agents/<role>.md` (or `~/.claude/agents/`). |
| `.claude/hooks/session-start.md` | Elon line → canonical path. |
| `.claude/hooks/guard-bash.py` | Keep protecting canonical `templates/agent-team/.claude/agents/`; optional: block writes to `<project>/.claude/agents/<known-team-role>.md`. |
| `.claude/hooks/tests/test_team_gates.py` | Role gate paths: dotfiles canonical + `docs/agents`; drop expectation that projects commit role files. |
| `.agents/skills/{elon,crew,team-grill-backlog,staging-review}/SKILL.md` | Read paths → `~/.claude/agents/<role>.md` or dotfiles canonical. |
| `.claude/agents/elon.md` | Owner-Reserved list: “role file changes” → dotfiles path only. |

### Dotfiles scripts and docs (outside template)

| Path | Change |
| --- | --- |
| `script/adopt-agent-team.sh` | **Stop copying** `.claude/agents/*.md` into projects; `--reset` no longer merges role files. Optionally write `.claude/agent-team-roles` marker file listing dotfiles SHA. |
| `script/sync-team-skills.sh` | No change to role files (skills only). |
| `script/team-audit.sh` | Budget/receipt/wording: audit **template + dotfiles** roles only; add **`no-project-roles`** finding if `<project>/.claude/agents/<team-role>.md` exists. Remove project from `receipt_check` for `.claude/agents`. |
| `script/agent-team.sh` | `project` / `reset`: do not require or install `<project>/.claude/agents/`. |
| `script/lead-merge.sh` | Protected paths: treat `templates/agent-team/.claude/agents/` as the role path; projects must not land role edits. |
| `script/weekly-skill-impact.sh` | Already iterates dotfiles template agents (OK). |
| `script/tests/release-guard-rules.sh` | Prefer dotfiles canonical path (already falls back to template). |
| `script/tests/{team-audit,lead-merge,lead-merge-text-lane,head-checks,role-word-budget,agent-team,release-guard-rules}.test.sh` | Update fixtures: no project `.claude/agents/` for team roles. |
| `docs/agents/team-reference.md`, `agent-team-architecture.md` | Document dotfiles-only roles and facts split. |
| `.agents/skills/orca-team/SKILL.md` | Detect team via `docs/agents/team.md` or marker, not `project/.claude/agents/elon.md`. |

### SessionStart hook

`script/agent-project-autoinit.sh` does **not** reference `.claude/agents/` (seeds `docs/agents/issue-tracker.md` only). SessionStart role text lives in adopted `templates/agent-team/.claude/settings.json` and `session-start.md` (above).

---

## 4. Migration (ordered PRs)

### PR A — dotfiles (foundation)

1. Implement §1–§3 in dotfiles (roles, `setup-claude-code.sh`, `adopt-agent-team.sh`, `team-audit.sh`, docs).
2. Add `team-audit` / `adopt-agent-team --check` rule: **fail** if any of the eight `*.md` files exist under `<project>/.claude/agents/`.
3. Owner-approved trailer on dotfiles role commits only.
4. Run `setup-claude-code.sh` on coordinator + fleet (manual checklist in PR body).

### PR B — `riben.life`

1. Delete `.claude/agents/{elon,architect-pm,fullstack-dev,qa-sdet,release-manager,sales-marketing,secops-finops,support-csm}.md`.
2. Delete `.claude/agent-team-baseline/*.sha256` if present.
3. Merge any project-only lines into `docs/agents/team-facts.md` / `deploy-facts.md` / role-work docs.
4. Re-run `sync-team-skills.sh`; CI or `team-audit.sh --check` must pass **no-project-roles**.
5. Smoke: spawn one worker per role; confirm `Read` resolves canonical path.

### PR C — `pstv`

Same steps as PR B.

### PR D — other agent-team projects

Repeat B/C pattern; track in `docs/agents/team-reference.md` “configured” list.

**Enforcement check (shared):**

```bash
# proposed helper (name TBD): script/check-no-project-team-roles.sh
for role in elon architect-pm fullstack-dev qa-sdet release-manager sales-marketing secops-finops support-csm; do
  [ -f ".claude/agents/$role.md" ] && exit 1
done
```

Wire into `team-audit.sh` and project CI (`head-checks` or existing audit job).

---

## 5. Risks, recommendation, owner A/B

### Risks

| Risk | Mitigation |
| --- | --- |
| Stale project copy shadows user agents | Delete copies + CI fail on reintroduction. |
| Hosts without fresh symlinks | `install.sh` / fleet doc; `team-audit` optional check `~/.claude/agents/elon.md` → dotfiles. |
| Cursor session cwd in dotfiles worktree | Absolute paths in worker specs (already required). |
| Custom per-project roles (e.g. old `tech-lead.md`) | Explicit owner policy: remove or rename; not in the eight. |
| `Owner-approved` trailer scope | Only dotfiles role path in receipt gate. |

### Recommendation

**Adopt user-level symlinks from canonical template + hard ban on project team role files.** Matches Claude Code docs, keeps one git source, preserves project facts in `docs/agents/*`, minimizes drift from `adopt-agent-team` copies.

### Owner decisions (A/B)

| ID | Question | Option A (recommended) | Option B |
| --- | --- | --- | --- |
| **A1** | Canonical git path | Keep `templates/agent-team/.claude/agents/` (adoption bundle stays colocated) | Move to `.agents/claude/agents/` next to Laravel agents (single `~/.claude/agents/` tree) |
| **A2** | Machine install | `setup-claude-code.sh` symlinks each team role into `~/.claude/agents/` | Document manual `orca`/`claude` `--agents` JSON injection only (no install hook) |
| **A3** | Project detection for Orca team | `docs/agents/team.md` exists + no forbidden role files | New marker `.claude/agent-team-roles` with dotfiles role SHA |
| **A4** | Extra project-only roles later | Forbidden until a separate spec | Allow `<project>/.claude/agents/<custom>.md` with names outside the eight |

---

## Appendix: full grep file list (item 3)

```
templates/agent-team/docs/agents/team.md
templates/agent-team/docs/agents/team-facts.md
templates/agent-team/docs/agents/engineering-integration.md
templates/agent-team/docs/agents/daily-run.md
templates/agent-team/.claude/agents/elon.md
templates/agent-team/.claude/settings.json
templates/agent-team/.claude/model-routing.md
templates/agent-team/.claude/hooks/session-start.md
templates/agent-team/.claude/hooks/guard-bash.py
templates/agent-team/.claude/hooks/tests/test_team_gates.py
templates/agent-team/.agent/skills/elon/SKILL.md
templates/agent-team/.agents/skills/elon/SKILL.md
templates/agent-team/.agent/skills/crew/SKILL.md
templates/agent-team/.agents/skills/crew/SKILL.md
templates/agent-team/.agent/skills/team-grill-backlog/SKILL.md
templates/agent-team/.agents/skills/team-grill-backlog/SKILL.md
templates/agent-team/.agent/skills/staging-review/SKILL.md
templates/agent-team/.agents/skills/staging-review/SKILL.md
.agents/skills/orca-team/SKILL.md
docs/agents/team-reference.md
docs/agents/agent-team-architecture.md
script/adopt-agent-team.sh
script/agent-team.sh
script/agent-team.test.sh
script/team-audit.sh
script/team-audit.test.sh
script/lead-merge.sh
script/weekly-skill-impact.sh
script/tests/release-guard-rules.sh
script/tests/release-guard-rules.test.sh
script/tests/lead-merge.test.sh
script/tests/lead-merge-text-lane.test.sh
script/tests/head-checks.test.sh
script/tests/role-word-budget.test.sh
```
