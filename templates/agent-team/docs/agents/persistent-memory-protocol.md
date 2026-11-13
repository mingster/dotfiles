# Persistent Memory Protocol: active_run.md

Against context loss, hallucinations and repeated errors, every multi-slice unit or crew lane keeps a markdown ledger, `active_run.md`, in the working directory or worktree root.

## 1. Single Execution Ledger (`active_run.md`)

Written once before modifying code, and again only when blocked or at a handoff. Task list, git and the final report hold the rest.

```markdown
# Active Run: [Task Slug or Title]

## 1. Objective and Scope Boundaries
- **Primary Goal**: Clear definition of the verifiable outcome in one or two sentences.
- **Allowed Files Whitelist**:
  - `path/to/allowed/file1.ts`
  - `path/to/allowed/file2.ts`
- **Forbidden or Out of Scope**: Explicit list of files or systems that must not be touched.

## 2. Machine-Checkable Verification Criteria
- [ ] Test command: `<test command> path/to/test` (Expected: 0 failures)
- [ ] Type check: `~/dotfiles/script/heavy-gate.sh --measure -- bunx tsc --noEmit` (Expected: 0 errors)
- [ ] Linter: `bun run lint` (Expected: clean)

## 3. Execution Milestones
1. [ ] Step 1 (Red): Write failing reproduction or contract test.
2. [ ] Step 2 (Green): Minimal implementation satisfying test.
3. [ ] Step 3 (Refactor): Clean up code while maintaining green suite.
4. [ ] Step 4 (Review): Verify diff against spec and coding standards.

## 4. Current Execution Status
- Active Step: Step 2 (Green)
- Last Command Run: `<test command> path/to/test`
- Command Output: 3 passed, 1 failed

## 5. Decisions and Discoveries
- Discovery: The fake module still returns the old response shape.
- Decision: Handled transformation in application layer.

## 6. Known Blockers and Strike Tracker (Three-Strike Rule)
The rule itself is in `AGENTS.md` (Token budget); this section only records the count.
- Strike Count: 2 of 3
- Blockers Log:
  - Error: `AssertionError: expected true to be false` at `path/to/test.ts:42`
  - Attempted: 1) Updated mock return type; 2) Adjusted input params
  - Hard Stop: At strike 3, halt execution immediately and record full error context. Never guess blindly.

## 7. FinOps Cost Gate (10-Turn Checkpoint)
- Turn Count: 2 of 10
- Rule: After 10 autonomous turns, snapshot state to `active_run.md` and continue; never pause for the owner (`team.md`, Owner pauses). Stop only on the Three-Strike Hard Stop.

```

## 2. Alignment with SDLC

- Specifications and requirements live exclusively in the project's intent and spec folders (`intent.md` and `spec.md`). `active_run.md` is strictly an ephemeral execution ledger for active multi-slice tasks and does not replace the coordinator's child ledger (`docs/agents/team.md`, rule Child ledger).
- Enforce Zero-Env Disclosure: never record `.env` secrets or keys into markdown artifacts; use `[Omitted/Configured via Env]`.
- Once the branch is verified and merged, `active_run.md` is deleted or reset.

## 3. Why This Prevents Amnesia and Hallucination

1. **Context Compaction Resilience**: after compaction or a reset, re-read `active_run.md` on turn 1 to resume.
2. **Anchor Against Scope Creep**: read `active_run.md` before every tool call to stay within the allowlisted files.
3. **Loop Breaker and FinOps Gate**: strike and turn counts stop repeated failing fixes and runaway token use. The strike rule lives in `AGENTS.md`.
