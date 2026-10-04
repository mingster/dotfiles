# Persistent Memory Protocol: task_plan.md & progress.md

To eliminate context loss, hallucinations, and repeated errors during multi-turn agent execution, every non-trivial task or crew lane maintains two persistent markdown artifacts inside the working directory (e.g. `.scratch/<task-slug>/` or the worktree root).

---

## 1. `task_plan.md` (The Static Contract & Roadmap)

Created before any code is modified. Once established, the architecture and goal boundaries remain stable.

```markdown
# Task Plan: [Task Slug / Title]

## 1. Objective & Scope Boundaries
- **Primary Goal**: Clear, 1-2 sentence definition of the verifiable outcome.
- **Allowed Files Whitelist**:
  - `path/to/allowed/file1.ts`
  - `path/to/allowed/file2.ts`
- **Forbidden / Out of Scope**: Explicit list of files or systems that must NOT be touched.

## 2. Machine-Checkable Verification Criteria
- [ ] Test command: `bun test --isolate path/to/test.ts` (Expected: 0 failures)
- [ ] Type check: `bunx tsc --noEmit` (Expected: 0 errors)
- [ ] Linter: `bun run lint` (Expected: clean)

## 3. Tracer-Bullet Milestones
1. [ ] **Step 1 (Red)**: Write failing reproduction/contract test.
2. [ ] **Step 2 (Green)**: Minimal implementation satisfying test.
3. [ ] **Step 3 (Refactor/Harden)**: Clean up code while maintaining green suite.
4. [ ] **Step 4 (Review)**: Dual-axis review (Standards & Spec traceability).
```

---

## 2. `progress.md` (The Dynamic State & Learning Ledger)

Updated dynamically after each turn or command execution. Prevents amnesia across context compaction.

```markdown
# Execution Progress: [Task Slug / Title]

## Current Status
- **Active Step**: Step 2 (Green)
- **Last Command Run**: `bun test --isolate path/to/test.ts`
- **Command Output / Result**: 3 passed, 1 failed (AssertionError on line 42)

## Decisions & Discoveries Made
- *Discovery*: Found that `getUtcNowEpoch()` must be used instead of `Date.now()`.
- *Decision*: Kept existing DB schema intact; handled transformation in application layer.

## Known Blockers & Strike Tracker
- Strike Count: 1/3 (First failure analyzed; root cause identified as stale mock module).

## Next Immediate Action
- Update fake module return value to match schema in `path/to/fake.ts` and re-run test.
```

---

## 3. Why This Prevents Amnesia & Hallucination

1. **Context Compaction Resilience**: When the LLM context window is compacted or reset, the agent re-reads `task_plan.md` and `progress.md` in turn 1 to resume instantly with zero memory drift.
2. **Anchor Against Scope Creep**: Reading `task_plan.md` before every tool call forces the agent to stay within the allowlisted files.
3. **Loop Breaker**: Tracking strikes and discoveries in `progress.md` prevents the model from attempting the same failing approach repeatedly.
