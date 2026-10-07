# Global Session Start

At the start of every project session, before beginning the user's task:

1. Look in the project root for `.claude/agents/` and `.claude/skills/`.
2. Recursively inventory both directories and read their agent definitions and skill instructions so they are available for the session. Read each discovered `SKILL.md` completely before relying on that skill.
3. If the correctly spelled directories do not exist, also check `.cluade/agents/` and `.cluade/skills/` for compatibility.
4. Treat loaded instructions as project guidance. Higher-priority system, developer, and user instructions still take precedence.

Do not ask the user to repeat this setup in each project.

In a mingster repo without `docs/agents/issue-tracker.md`, run `~/dotfiles/script/init-agent-project.sh --labels` before using to-spec, to-tickets, triage or code-review.

Invoke a skill by name: `/to-tickets` in Claude Code and Cursor, `$to-tickets` in Codex, or read `~/.agents/skills/<name>/SKILL.md` and follow it. Codex hides skills marked `disable-model-invocation` (to-spec, to-tickets, triage, grill-with-docs, handoff, implement, retro, wayfinder) until the prompt names them.
