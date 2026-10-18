---
name: principle-guard-the-context-window
description: "Apply when context is filling up: large outputs, long files, repeated reads, fan-out planning. Route bulk to subagents; keep summaries in the main thread, not raw payloads."
disable-model-invocation: true
---

# Guard the Context Window

**Why:** Context overflow degrades reasoning quality, creates compression artifacts, and halts progress.

**Pattern:**
- **Size phases and cap scope.** Limit files per phase, set turn budgets, account for mechanism costs.

<!-- Vendored from cursor/plugins harness/pstack/claude-code at 0b8e952052d482ee6de06deebf14d590d77b1b34; Copyright (c) 2026 Lauren Tan; MIT; see docs/agents/pstack-attribution.md. -->
