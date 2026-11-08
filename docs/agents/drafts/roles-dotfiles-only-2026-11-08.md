# Spec: team role files live only in dotfiles

**Owner decision (2026-11-08):** Each Mingster team role is authored once in dotfiles. Projects may hold **only symlinks** under `.claude/agents/<role>.md` pointing into dotfiles — no copies, no `{{PROJECT_NAME}}` rendering, no generated regular files.

**Roles in scope:** `elon`, `architect-pm`, `fullstack-dev`, `qa-sdet`, `release-manager`, `sales-marketing`, `secops-finops`, `support-csm`.

**Settled (owner 2026-11-08, coordinator):** Project tree uses **symlink-only** role entries (not user-level-only with empty project dirs, and not committed file copies).

---

## 1. Canonical location and how Claude Code loads roles

### Where the unique content lives

| Layer | Path | Content |
| --- | --- | --- |
| **Canonical source (git, dotfiles)** | `~/dotfiles/templates/agent-team/.claude/agents/<role>.md` | Eight team roles; shared behaviour only; no per-project placeholders. |
| **Project discovery (git, each repo)** | `<project>/.claude/agents/<role>.md` | **Symlink only** → canonical file under dotfiles (see portability below). |
| **User-level (optional, unchanged)** | `~/.claude/agents/` | Laravel agents via `setup-claude-code.sh` today; team roles **need not** duplicate here if project symlinks exist. |

### Claude Code behavior (verified)

Per [Subagents](https://code.claude.com/docs/en/sub-agents) (2026):

- **Project** `.claude/agents/` is walked from cwd upward; definitions here take precedence over `~/.claude/agents/` when the same `name` is closer to the working directory.
- Symlinks in `.claude/agents/` are normal files from Claude Code’s perspective; content resolves from the link target.
- `claude --agent <name>` loads from project + user agent directories.

**Implication:** committed project symlinks give correct project-relative discovery for workers in project worktrees while keeping a single editable source in dotfiles.

### Symlink target portability (fleet: mini6, niteking, miniu, blueDevil)

| Approach | Git | Local dev | Worktree | CI without dotfiles |
| --- | --- | --- | --- | --- |
| **Relative symlink** (project → dotfiles) | Portable if every host keeps the same relative layout (e.g. `$HOME/projects/<repo>` and `$HOME/dotfiles`). | Works when `DOTFILES` path matches adopt script assumptions. | Same inode via git worktree checkout of `.claude/agents/*`; child worktrees see the symlink. | Fails or dangling link unless CI checks out dotfiles beside the project (document required layout). |
| **Absolute symlink** (`/Users/.../dotfiles/...`) | Committed path is host-specific; **do not commit** per-user absolutes. | Works on one machine. | Breaks on other hosts. | Unusable. |

**Recommendation:** `adopt-agent-team.sh` (or successor `link-agent-team-roles.sh`) writes **relative** symlinks from `<project>/.claude/agents/<role>.md` to `$(relpath "$PROJECT" "$DOTFILES/templates/agent-team/.claude/agents/<role>.md")`. Document the fleet invariant: `~/dotfiles` is the dotfiles repo and projects live under predictable siblings (or re-run the link script after clone). Refuse adoption when relative path cannot be computed (exit 2 with fix instructions).

Optional machine hook: `setup-claude-code.sh` does **not** need team-role symlinks in `~/.claude/agents/` when project symlinks are mandatory.

### Non–Claude Code workers (Cursor, Antigravity, Orca)

Worker specs may keep using either:

- Project path: read `<repo>/.claude/agents/<role>.md` (resolves through symlink), or
- Absolute canonical: `~/dotfiles/templates/agent-team/.claude/agents/<role>.md` for branch worktrees where a stale regular file must not exist.

Update `model-routing.md` to require symlink or canonical path, and to forbid a regular file at the project path.

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

**Role frontmatter `description`:** role title + “for the active project”; commercial name from `docs/agents/team-facts.md` § Product.

**Skills:** tier-2 team skills stay generated under `<project>/.agents/skills/` via `sync-team-skills.sh` (unchanged).

---

## 3. Touch points: templates, scripts, hooks, gates

Grep target: `.claude/agents` under `~/dotfiles` (34 paths, 2026-11-08) — appendix.

### Template tree (`templates/agent-team/`)

| Path | Change |
| --- | --- |
| `.claude/agents/*.md` | Strip `{{PROJECT_NAME}}`; pointer to `docs/agents/team-facts.md`. Canonical only. |
| `docs/agents/team.md` | Roles: canonical in dotfiles; projects commit symlinks only. |
| `docs/agents/team-facts.md` | Document symlink layout; Product section; worker paths via `.claude/agents/` (symlinks). |
| `docs/agents/engineering-integration.md`, `daily-run.md` | Keep `.claude/agents/<role>.md` paths (symlink-backed). |
| `.claude/model-routing.md` | Workers must not see a regular file at project role path; symlink or dotfiles canonical. |
| `.claude/settings.json`, `hooks/session-start.md` | `.claude/agents/<role>.md` (symlink) is fine. |
| `.claude/hooks/guard-bash.py` | Protect dotfiles canonical paths; block replacing symlinks with regular files in projects. |
| `.claude/hooks/tests/test_team_gates.py` | Gates on dotfiles canonical + `docs/agents`; project role paths are symlinks only. |
| `.agents/skills/{elon,crew,team-grill-backlog,staging-review}/SKILL.md` | `.claude/agents/<role>.md` via symlink. |

### Dotfiles scripts and docs

| Path | Change |
| --- | --- |
| `script/adopt-agent-team.sh` | Replace `copy_file` for roles with **symlink** to dotfiles canonical; drop `agent-team-baseline` sha256 conflict logic for roles; `--reset` refreshes broken links. |
| `script/team-audit.sh` | Budget/receipt on dotfiles template only; **`role-symlink`** finding per project (see §4). Remove receipt on project `.claude/agents` content commits (projects should not commit role body changes). |
| `script/agent-team.sh` | `project` installs symlinks, not copies. |
| `script/sync-team-skills.sh` | Unchanged (skills only). |
| `script/lead-merge.sh` | Reject PRs that replace a team role symlink with a regular file or edit role body via project path. |
| `.agents/skills/orca-team/SKILL.md` | Detect team via `elon.md` symlink or `docs/agents/team.md`. |
| `docs/agents/team-reference.md`, `agent-team-architecture.md` | Symlink-only contract. |

### SessionStart hook

`script/agent-project-autoinit.sh` does not touch roles. Role text in adopted `settings.json` / `session-start.md` uses `.claude/agents/<role>.md`.

---

## 4. Migration (ordered PRs)

### PR A — dotfiles (foundation)

1. Canonical roles + `adopt-agent-team.sh` symlink mode + `team-audit.sh` role-symlink checks + docs.
2. Implement `script/check-project-team-role-links.sh` (or fold into `team-audit.sh`):

```bash
# For each team role name:
#   - missing .claude/agents/<role>.md -> fail
#   - regular file (not symlink) -> fail
#   - symlink target must resolve and lie under $DOTFILES/templates/agent-team/.claude/agents/
#   - optional: target basename must match role
```

3. Owner-approved trailer on dotfiles role commits only.
4. Document CI: checkout dotfiles adjacent to project or set `DOTFILES` and run link script before audit.

### PR B — `riben.life`

1. Remove regular-file `.claude/agents/*.md`; add symlinks via adopt/link script.
2. Delete `.claude/agent-team-baseline/*.sha256`.
3. Move any project-only lines into `docs/agents/team-facts.md` / `deploy-facts.md`.
4. `team-audit` / link check green; smoke one worker per role.

### PR C — `pstv`

Same as PR B.

### PR D — other agent-team projects

Repeat; track in `team-reference.md`.

---

## 5. Risks and remaining owner decisions

### Risks

| Risk | Mitigation |
| --- | --- |
| Regular file reintroduced in project | CI + `team-audit` fail on non-symlink. |
| Dangling symlink (dotfiles not cloned) | Adopt script + fleet README; audit reports unresolved target. |
| Wrong relative depth after repo move | Re-run link script; document layout. |
| CI runner without dotfiles | Job checks out dotfiles or skips role-audit with explicit failure. |
| Worktree on old branch missing symlinks | Symlinks are tree-wide via git; merge main before worker spawn. |
| Custom `tech-lead.md` etc. | Out of scope for the eight; separate policy. |

### Recommendation

**Canonical content in dotfiles; each project commits only relative symlinks; enforcement fails on regular files.**

### Owner decisions (unset only)

| ID | Question | Option B (recommended) | Notes |
| --- | --- | --- | --- |
| **A3** | Orca “has agent team” detection | `docs/agents/team.md` + valid role symlinks | vs marker file with SHA |
| **A4** | Extra project-only roles later | Allow only names outside the eight as symlinks or separate spec | vs forbid all extras |

*(A1 canonical path in `templates/agent-team/.claude/agents/` and A2 project symlinks via adopt script are settled.)*

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
