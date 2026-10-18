---
name: principle-laziness-protocol
description: "Apply when refactoring, evaluating diff size, or tempted to add abstractions, layers, or signal threading. Bias toward deletion and the smallest change that solves the problem."
disable-model-invocation: true
---

# Laziness Protocol

- **Consolidate decisions.** Do not repeat the same choice in several places. Put it behind one source of truth and pass the result as a simple flag.
- **Minimize the diff.** Make the smallest change that solves the problem. Fewer lines beat "elegant" boilerplate.

<!-- Vendored from cursor/plugins harness/pstack/claude-code at 0b8e952052d482ee6de06deebf14d590d77b1b34; Copyright (c) 2026 Lauren Tan; MIT; see docs/agents/pstack-attribution.md. -->
