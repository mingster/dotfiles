# Skills inventory

Reference for the three-tier skill architecture across `~/dotfiles`, `templates/agent-team/`, and adopted projects (**<project-a>**, **<project-b>** and future adoptions).

## Three-tier skill layout

Skills are split into three tiers so general engineering skills load everywhere on a configured Mac, team workflow skills travel inside each adopted repository (working in fresh clones, cloud sessions and Orca child worktrees), and product-specific skills stay inside their own repo.

| Tier | What | Canonical source | How a project sees it |
| --- | --- | --- | --- |
| **Tier 1: General** | 22 vendored Matt Pocock skills (`.agents/skills/.mattpocock-upstream`), dotfiles shared skills (`agent-browser`, `capture-intent`, `create-pr`, `laravel-inertia-react-structure`, `orca-team`, `write-spec`), and Orca-installed skills (`orchestration`, `orca-cli`, `orca-per-workspace-env`, `orca-computer-use`, `orca-emulator`, `orca-emulator-android`, `orca-jira`, `orca-linear`, `jira-tickets`, `linear-tickets`) | `~/dotfiles/.agents/skills/<name>/` (tracked) and `orca skills install --all` (untracked in home skill dirs) | Individual symlinks in `~/.agents/skills/<name>` and `~/.claude/skills/<name>` created by `script/setup-agent-skills.sh` (`install.sh`). No project copy. |
| **Tier 2: Team** | Team workflow skills (`elon`, `ceo`, `crew`, `deploy`, `staging-review`, `grill-backlog`, `team-grill-backlog`, `team-audit`, `wrap-up`) and vendored pstack skills (`poteto-mode` with `ORCA-ADAPTER.md` and playbooks, `ketchup`, `recall`, `show-me-your-work`, `correct`, `unslop`, `bro`, `benchmark-checklist`, and the 23 `principle-*` skills) | `~/dotfiles/templates/agent-team/.agents/skills/<name>/` | Committed generated copies in `<project>/.agents/skills/<name>/` with relative links in `<project>/.claude/skills/` and `<project>/.cursor/skills/`, written by `script/sync-team-skills.sh`. |
| **Tier 3: Project** | Product-specific skills (for example `action-scaffold`, `e2e-test-scaffold`, `i18n-sync`, `payment-plugin`, `store-admin-crud` in <project-a>; `roku-qa`, `jellyfin-web-port`, `paypal-webhooks` in <project-b>) | `<project>/.agents/skills/<name>/`, tracked in that repo | Tracked relative symlinks `.claude/skills/<name>` and `.cursor/skills/<name>` pointing to `../../.agents/skills/<name>`. |

Tier 2 skills are kept out of `~/dotfiles/.agents/skills/` so they do not load into unrelated repositories on the Mac. Product facts never live inside Tier 2 skills; they live in the project's `docs/agents/team-facts.md`, `docs/agents/deploy-facts.md` and `docs/agents/daily-run.md`.

## How each IDE and CLI loads skills

| Tool | Global skills read from | Workspace skills read from | Notes |
| --- | --- | --- | --- |
| **Claude Code** | `~/.claude/skills` (real directory with individual skill links) | `<repo>/.claude/skills` | Loads every skill; skips `disable-model-invocation` skills in role `skills:` preloads. |
| **Cursor** | `~/.claude/skills` and `~/.agents/skills` | `<repo>/.cursor/skills` | No `~/.cursor/skills` link in `$HOME` (would list every shared skill twice). |
| **Antigravity** | `~/.gemini/antigravity/skills` and `~/.gemini/antigravity-cli/skills` (linked by `script/setup-antigravity.sh`) | `<repo>/.agent/skills` (relative link to `../.agents/skills`) | Hides `disable-model-invocation` skills until named in the prompt or via `/skill-name`. |

## Syncing Tier 2 team skills (`script/sync-team-skills.sh`)

```bash
~/dotfiles/script/sync-team-skills.sh [--check] [--force] [<project-root> ...]
```

* Copies every directory with a `SKILL.md` under `templates/agent-team/.agents/skills/` into `<project>/.agents/skills/<name>/` and writes relative links in `.claude/skills/<name>` and `.cursor/skills/<name>`.
* Stamps each copied `SKILL.md` immediately after its frontmatter with `<!-- Generated from dotfiles templates/agent-team/.agents/skills/<name> by script/sync-team-skills.sh, do not edit. ... source-sha256: <hash> -->`.
* `--check` writes nothing and exits 1 when a copy is missing, a file differs, an extra file is present, a link is missing, or a retired template skill still lingers in the project. `script/team-audit.sh` runs `--check` on every audited project.
* Refuses to overwrite a hand-written skill directory (no stamp) without `--force`, and refuses `$HOME` or the dotfiles checkout so it can never write into the Tier 1 tree.

## Orca owns `orchestration`; dotfiles owns `orca-team`

* Orca ADE installs and updates its official `orchestration` skill into `~/.agents/skills/orchestration` and `~/.claude/skills/orchestration` via `orca skills install --all`. Dotfiles ignores `.agents/skills/orchestration/` in `.gitignore` so git never shadows Orca's copy.
* Our coordinator and pane extensions live in `.agents/skills/orca-team/`: the Elon coordinator rules, colored worker panes (`worker-panes.sh`, `worker-pane.sh`, `role-colors.tsv`), pane cleanup and retry (`worker-pane-close.sh`, `worker-pane-retry.sh`), stall detection (`worker-watch.sh`), and the usage-gated launcher (`worker-start-check.sh`).
* Keep `orca-team` out of `.agents/.skill-lock.json`; `script/team-audit.sh` verifies both the lock exclusion and the presence of all `orca-team` helpers.
* Run `bash script/setup-agent-skills.sh` to create real `~/.agents/skills` and `~/.claude/skills` directories, preserve non-dotfiles skills, link tracked Tier 1 skills, and run `orca skills install --all`. Run `script/check-skill-collisions.sh` to detect shadowed skills or broken links.

## Upstream Matt Pocock and pstack skill sync

* **Matt Pocock skills (`script/sync-mattpocock-skills.sh`):** `.agents/skills/.mattpocock-upstream` records the synced upstream commit SHA and the 22 vendored skill names (`code-review`, `codebase-design`, `diagnosing-bugs`, `domain-modeling`, `grill-me`, `grill-with-docs`, `grilling`, `handoff`, `implement`, `improve-codebase-architecture`, `prototype`, `research`, `resolving-merge-conflicts`, `retro`, `setup-matt-pocock-skills`, `tdd`, `to-spec`, `to-tickets`, `triage`, `wayfinder`, `wizard`, `writing-for-agents`). On refresh, the script reapplies two local conventions: `CONTEXT.md` naming (in place of upstream `GLOSSARY.md`) and `.agents/skills/.mattpocock-local.patch` (the machine-checkable ticket contract sections in `to-tickets`). Upstream `implement-spec` (uses subagents instead of Orca workers) and `pr` (conflicts with our PR body rules) remain unvendored.
* **pstack template skills (`script/.pstack-template-upstream`):** vendored under `templates/agent-team/.agents/skills/` with Orca translation rules in `poteto-mode/ORCA-ADAPTER.md`.
* **Weekly maintenance (`script/weekly-update.sh`):** checks upstream Matt Pocock skills, pstack skills, Bun and Node LTS, refreshes pins, runs `sync-team-skills.sh` across configured projects, verifies test suites, and opens three PRs plus one summary for the owner's go.
