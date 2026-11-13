# Persistent Memory Protocol: active_run.md

Every multi-slice unit or crew lane keeps one markdown ledger, `active_run.md`, in the working directory or worktree root. Write it once before modifying code, and again only when blocked or at a handoff; the task list, git and the final report hold the rest.

```markdown
# Active Run: <task>

## 1. Objective and scope
- Goal (verifiable, one or two sentences); allowed files; out of scope.

## 2. Verification criteria
- [ ] `<command>` (<expected result>)

## 3. Milestones
1. [ ] Red: failing reproduction or contract test.
2. [ ] Green: minimal implementation.
3. [ ] Refactor with the suite green.
4. [ ] Review the diff against spec and standards.

## 4. Status (active step, last command, its output)

## 5. Decisions and discoveries

## 6. Strikes (rule in `AGENTS.md`, Token budget)
- Strike count: <n> of 3. Blockers log: error, location, attempts.
- At strike 3, halt and record the full error context. Never guess blindly.

## 7. Turn checkpoint
- Turn count: <n> of 10. After 10 autonomous turns, snapshot state here and continue; never pause for the owner (`team.md`, Owner pauses). Stop only on the strike 3 hard stop.
```

## Rules

- Specs live only in `intent.md` and `spec.md`; `active_run.md` is an ephemeral ledger and does not replace the coordinator's child ledger (`docs/agents/team.md`, rule Child ledger).
- Zero-Env Disclosure: never record `.env` secrets or keys in markdown; write `[Omitted/Configured via Env]`.
- After compaction or a reset, re-read `active_run.md` on turn 1. Read it before every tool call to stay within the allowed files.
- Once the branch is verified and merged, delete or reset `active_run.md`.
