# Spec: team role files live only in dotfiles

**Owner decision (2026-11-08):** Each Mingster team role is authored once in dotfiles. Projects may hold **only local symlinks** under `.claude/agents/<role>.md` pointing into dotfiles (no copies, no `{{PROJECT_NAME}}` rendering, no generated regular files, **nothing committed under `.claude/agents/` for the eight team roles**).

**Roles in scope:** `elon`, `architect-pm`, `fullstack-dev`, `qa-sdet`, `release-manager`, `sales-marketing`, `secops-finops`, `support-csm`.

**Settled (owner 2026-11-08, coordinator):** Project tree uses **symlink-only** role entries, created per checkout (not user-level-only with empty project dirs, and not committed file copies).

---

## 1. Canonical location and how Claude Code loads roles

### Where the unique content lives

| Layer | Path | Content |
| --- | --- | --- |
| **Canonical source (git, dotfiles)** | `~/dotfiles/templates/agent-team/.claude/agents/<role>.md` | Eight team roles; shared behaviour only; no per-project placeholders. |
| **Project discovery (local, not in git)** | `<project>/.claude/agents/<role>.md` | **Symlink only** → resolved canonical file under dotfiles (see §1.1). |
| **User-level (optional, unchanged)** | `~/.claude/agents/` | Laravel agents via `setup-claude-code.sh` today; team roles **need not** duplicate here when project symlinks exist. |

### Claude Code behavior (verified)

Per [Subagents](https://code.claude.com/docs/en/sub-agents) (2026):

- **Project** `.claude/agents/` is walked from cwd upward; definitions here take precedence over `~/.claude/agents/` when the same `name` is closer to the working directory.
- Symlinks in `.claude/agents/` are normal files from Claude Code’s perspective; content resolves from the link target.
- `claude --agent <name>` loads from project + user agent directories.

**Implication:** local project symlinks give correct discovery in any checkout depth (main tree, Orca worktree, nested app folder) while keeping a single editable source in dotfiles.

### 1.1 Link model (replaces committed relative symlinks)

**Problem:** A **relative** symlink checked into git cannot work on every host. Projects live at different depths (`~/projects/<repo>` vs `~/orca/workspaces/<repo>/<lane>`), and `~/dotfiles` is itself sometimes a symlink (for example to `~/GitHub/dotfiles`). Git would store one relative path; worktrees would inherit a broken or wrong target.

**Model:**

1. **Canonical content stays in dotfiles git only** (template tree above).
2. **Projects never commit** the eight team role paths. Each checkout creates them with `script/adopt-agent-team.sh` (or successor `link-agent-team-roles.sh`): resolve `DOTFILES` (`$DOTFILES` or `$HOME/dotfiles`, then `pwd -P` so a `~/dotfiles` symlink is real), compute `canonical="$DOTFILES/templates/agent-team/.claude/agents/<role>.md"`, and `ln -sf "$canonical" "$PROJECT/.claude/agents/<role>.md"`. Use an **absolute** target so depth and dotfiles layout do not matter.
3. **Ignore locally, document in git:** add the eight basenames to the project **`.gitignore`** (not `.git/info/exclude`). Ignore rules are shared policy every clone and CI job sees; `exclude` is invisible and machine-local. Adopt seeds the block; `team-audit` fails if git still tracks a team role file.

| Concern | Committed relative symlink (rejected) | Local absolute symlink + gitignore |
| --- | --- | --- |
| Orca lane worktree | Often wrong `../` depth | Link script runs in that worktree root |
| `~/dotfiles` → other path | Breaks if relative path assumed | `pwd -P` on dotfiles root |
| CI without dotfiles | Broken checkout | Git has no role files; audit checks tracking only |
| Fresh clone | Needs same fleet layout | Run adopt/link once dotfiles exists |

Optional: `setup-claude-code.sh` does **not** need team-role symlinks in `~/.claude/agents/` when project symlinks are mandatory.

### 1.2 When links are created or repaired

| Trigger | Today (verified 2026-11-08) | Spec change |
| --- | --- | --- |
| **Adoption / `--reset`** | `adopt-agent-team.sh` **copies** role files | Replace copy with link step above; drop `agent-team-baseline` sha256 for roles. |
| **Orca new worktree** | `script/worktree-setup.sh` (Orca repo settings / `orca.yaml` per `model-routing.md`) fetch/ff + `bun install` only; **no role links**. | Chain `link-agent-team-roles.sh` in the setup hook after the tree exists. |
| **Session start** | `SessionStart`: `session-start.md` + `state-of-play.sh`; autoinit touches `docs/agents` only. | On `startup\|clear`, link script when `docs/agents/team.md` exists and any team role is missing, not a symlink, or broken. |

### 1.3 Host without dotfiles

No link script can run. Tier-2 skills still work (committed copies, ADR-0001). Roles need dotfiles on the host (`DOTFILES` or clone). Briefs may cite the canonical template path. `team-audit`: enforce **`role-tracked`**; **`role-symlink`** is `NOTE` or skip when dotfiles is absent.

### Non-Claude Code workers (Cursor, Antigravity, Orca)

Worker specs may use project path when links exist, or absolute canonical under dotfiles. Update `model-routing.md` to require symlink or canonical path and to forbid a regular file at the project path.

---

## 2. Project-specific facts (no placeholders in role files)

Role files hold **shared** behaviour only. Per-repo facts live in project-owned docs; roles **point** with stable paths (no templating).

| Fact type | Project-owned file | How the role references it |
| --- | --- | --- |
| Repo, PR target, lint/test commands, review checklist, changelog layout, Orca flags | `docs/agents/team-facts.md` | “Read `docs/agents/team-facts.md` (Repository, Checks, Review, …).” |
| Hosts, deploy commands, production gate, RM host | `docs/agents/deploy-facts.md` | Same pattern; `release-manager` and `deploy` skill already expect this. |
| Daily run, support copy, display name | `docs/agents/team-facts.md` (§ Daily run, Product, …) | Roles point at stable project paths; no `{{PROJECT_NAME}}`. |
| Shared process (not product-specific) | `~/dotfiles/templates/agent-team/docs/agents/*.md` | Unchanged (`team.md`, `elon-dispatch.md`, …). |

**Role frontmatter `description`:** role title + “for the active project”; commercial name from `docs/agents/team-facts.md` § Product.

**Skills:** tier-2 team skills stay generated under `<project>/.agents/skills/` via `sync-team-skills.sh` (unchanged).

---

## 3. Touch points: templates, scripts, hooks, gates

Grep target: `.claude/agents` under `~/dotfiles` (34 paths, 2026-11-08); see appendix.

### Template tree (`templates/agent-team/`)

| Path | Change |
| --- | --- |
| `.claude/agents/*.md` | Strip `{{PROJECT_NAME}}`; pointer to `docs/agents/team-facts.md`. Canonical only. |
| `docs/agents/team.md` | Roles: canonical in dotfiles; projects hold **local** symlinks only; gitignore the eight names. |
| `docs/agents/team-facts.md` | Link script + gitignore; worker paths via `.claude/agents/` when linked. |
| `docs/agents/engineering-integration.md`, `daily-run.md` | Keep `.claude/agents/<role>.md` paths (symlink-backed). |
| `.claude/model-routing.md` | Workers must not see a regular file at project role path; setup hook links roles in new worktrees. |
| `.claude/settings.json`, `hooks/session-start.md` | SessionStart self-heal for role links (see §1.2). |
| `.claude/hooks/guard-bash.py` | Protect dotfiles canonical paths; block replacing symlinks with regular files in projects. |
| `.claude/hooks/tests/test_team_gates.py` | Gates on dotfiles canonical + `docs/agents`; project role paths are symlinks only. |
| `.agents/skills/{elon,crew,team-grill-backlog,staging-review}/SKILL.md` | `.claude/agents/<role>.md` via symlink. |

### Dotfiles scripts and docs

| Path | Change |
| --- | --- |
| `script/adopt-agent-team.sh` | Link roles (absolute target); seed gitignore block; `--reset` refreshes links. |
| `script/team-audit.sh` | Budget/receipt on dotfiles template only; **`role-symlink`** per project (§4); fail **`role-tracked`** if git indexes a team role path. |
| `script/agent-team.sh` | Project install calls link step, not copies. |
| `script/worktree-setup.sh` | Optional: invoke role link for agent-team repos (or document chained hook). |
| `script/sync-team-skills.sh` | Unchanged (skills only). |
| `script/lead-merge.sh` | Reject PRs that add or change committed team role files or replace a symlink with a regular file. |
| `.agents/skills/orca-team/SKILL.md` | Detect team via `docs/agents/team.md` plus valid local links (A3). |
| `docs/agents/team-reference.md`, `agent-team-architecture.md` | Local symlink contract. |

---

## 4. Enforcement (`team-audit` / link check)

For each in-scope role name:

- **`git ls-files`** lists `.claude/agents/<role>.md` → **`role-tracked`** (must be untracked; only gitignore may mention it).
- Path missing → **`role-symlink`** fail (on hosts with dotfiles).
- Regular file (not symlink) → fail.
- Symlink target does not resolve or is not under `$DOTFILES/templates/agent-team/.claude/agents/` → fail.
- Optional: basename must match role.

**CI without dotfiles:** assert no tracked team role files. Full **`role-symlink`** resolution only when the job checks out dotfiles and runs the link script.

---

## 5. Migration (ordered PRs)

### PR A (dotfiles foundation)

Canonical roles, adopt link mode, `team-audit` checks, owner-approved trailers on dotfiles role commits only, Orca setup + SessionStart self-heal docs.

### PR B+ (each agent-team project: `riben.life`, `pstv`, …)

Remove committed role files; add gitignore; run link script; drop baselines; move facts into `team-facts.md` / `deploy-facts.md`; `team-audit` green; smoke one worker per role.

---

## 6. Risks and remaining owner decisions

### Risks

| Risk | Mitigation |
| --- | --- |
| Regular file or committed role in project | `team-audit` **`role-tracked`** + **`role-symlink`**. |
| Dangling symlink (dotfiles not cloned) | Self-heal + fleet README; audit reports unresolved target. |
| Forgot link after clone | SessionStart self-heal; adopt on boarding. |
| CI without dotfiles | `role-tracked` only; full link audit in a dotfiles job. |
| Custom `tech-lead.md` etc. | Out of scope for the eight; separate policy. |

### Recommendation

**Canonical content in dotfiles; each project keeps absolute local symlinks and gitignored paths; enforcement fails on regular files and on any committed team role file.**

### Owner decisions (unset only)

| ID | Question | Option B (recommended) | Notes |
| --- | --- | --- | --- |
| **A3** | Orca “has agent team” detection | `docs/agents/team.md` + valid role symlinks | vs marker file with SHA |
| **A4** | Extra project-only roles later | Allow only names outside the eight as symlinks or separate spec | vs forbid all extras |

*(A1 canonical path in `templates/agent-team/.claude/agents/` and A2 local symlinks via adopt/link script are settled.)*

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
