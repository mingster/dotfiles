---
name: tune-agent-docs
description: Cut words from agent guide files (role files, team docs, AGENTS.md) without changing any rule. Use when asked to tune, trim or shrink agent docs.
---

# Tune agent docs

Agents load these files every turn. No rule changes. Target: the cut the brief names (default 20% of total words); line polish alone gives about 1%.

1. **Baseline.** Copy the targets to scratch; record `wc -w` per file.
2. **Parsed strings.** Grep `script/`, `.claude/hooks/` and `templates/agent-team/.claude/{hooks,bin}/` for each target file name. List every string they match in that file (headings, phrases, paths, frontmatter keys) and every heading other docs cite by name. Keep them byte-identical.
3. **Edit.** Across files first: keep each rule in one place and replace repeats with a pointer (`team.md`, <section>); drop rationale, history, dates and examples that state no rule; use tables for rule lists. Then follow `writing-for-agents` (`.agents/skills/writing-for-agents/SKILL.md`) and run `unslop` (`templates/agent-team/.agents/skills/unslop/SKILL.md`) on every line. Name any file that cannot drop and why. Keep frontmatter `name`, `tools`, `model`; shrink a `description` only keeping its trigger meaning.
4. **Rule map.** One row per moved or merged rule: old `file:line`, the rule, new `file:line`. No rule dropped, loosened or tightened. A wrong, stale or contradicting rule goes under "Decisions to review", unchanged.
5. **Verify.** Links and pointers resolve; each step 2 string survives (`grep -F`, from a script file when a string trips the Bash guard); `bash script/checks-local.sh` exits 0; the target is met; role files stay under 800 words. A suite failing identically on main is pre-existing.
6. **Self-check.** As the verifier, find every old rule in the new files.
7. **PR body.** Rule map, parsed strings, word counts per file, decisions to review, each step 5 command with its output. Role file commits carry the `Owner-approved:` trailer (`team.md`, Role changes).
