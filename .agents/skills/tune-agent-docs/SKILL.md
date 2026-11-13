---
name: tune-agent-docs
description: Cut words from agent guide files (role files, team docs, AGENTS.md) without changing any rule. Use when asked to tune, trim or shrink agent docs.
---

# Tune agent docs

Readers are agents loading these files every turn; every word costs tokens. No rule changes.

1. **Baseline.** Copy the target files to scratch and record `wc -w` per file.
2. **Parsed strings.** Grep `script/`, `script/tests/`, `.claude/hooks/`, `templates/agent-team/.claude/hooks/` and `templates/agent-team/.claude/bin/` for each target file name. List every string they match, extract or count in that file: headings, quoted phrases, paths, frontmatter keys. Headings other docs cite by name (`team.md`, Owner pauses) count too. These stay byte-identical.
3. **Edit.** Follow `writing-for-agents` (`.agents/skills/writing-for-agents/SKILL.md`) for structure and pointers, then run `unslop` (`templates/agent-team/.agents/skills/unslop/SKILL.md`) on every line. Keep frontmatter `name`, `tools` and `model`; shrink a `description` only when its trigger meaning stays.
4. **Rule map.** One row per rule in the old files: old `file:line`, the rule, new `file:line` or `merged into <file:line>`. No rule dropped, loosened or tightened. A rule that looks wrong, stale or contradicts another goes under "Decisions to review", unchanged in the files.
5. **Verify.** Links and pointers resolve; each step 2 string is still present (`grep -F`, from a script file when a string trips the Bash guard); `bash script/checks-local.sh` exits 0; total words drop; each role file is under 800 words. Run any failing suite on clean main too and report it as pre-existing only when it fails the same there.
6. **Self-check.** Re-read the rule map as the verifier would and find every old rule in the new files.
7. **PR body.** Rule map, parsed strings, before and after word counts, decisions to review, and each step 5 command with its output. Role file commits carry the `Owner-approved:` trailer (`team.md`, Role changes).
