# Persistent Memory Protocol: active_run.md

Multi-slice work uses **Session pickup** and **Pause safely** (`poteto-mode/playbooks/session-pickup.md`, `pause-safely.md`): a worktree `.scratch/` handoff plus a git-ignored `active_run.md` in the worktree root for execution state. `active_run.md` holds only what `strikes.py` reads under `[Blockers]` and strike count; the coordinator child ledger stays in `team.md` Delivery contract 3.

## 1. Execution ledger (`active_run.md`)

Written once before code changes, and again only when blocked or at handoff.

```markdown
# Active Run: [Task Slug or Title]

## Objective and allowed files
- Primary goal in one or two sentences
- Allowed paths whitelist and forbidden paths

## Verification (VERIFY)
- [ ] Commands from the brief, with expected exits

## Status
- Active step, last command, output summary

## Blockers (strikes.py)
- Strike count and blocker log only (Three-Strike rule lives in AGENTS.md)
```

## 2. Alignment

- Intent and spec live in `docs/intent/`; `active_run.md` is ephemeral execution state only.
- Never record secrets in markdown; use `[Omitted/Configured via Env]`.
- Delete or reset `active_run.md` after merge; handoff facts live in `.scratch/` per Session pickup.

## 3. Why this prevents drift

Compaction or restart: re-read `active_run.md` and `.scratch/` on turn 1. Reading allowed files before edits limits scope creep. Strike counts stop blind retries; tooling failures do not increment strikes (`team.md` Delivery contract 8).
