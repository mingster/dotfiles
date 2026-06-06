# Shared Notes

Project-specific learnings worth keeping across all projects.

## Adding a note

From any project directory, run:

    ~/dotfiles/script/contribute-to-agents.sh <topic> "What I learned"

Omit the message to open `$EDITOR` for a longer entry.

## Referencing a note from a project

In the project's `CLAUDE.md`:

    @notes/laravel.md

## Structure

One file per topic. All files here are linked into `~/.claude/notes/` by
`setup-claude-code.sh`, so they are available to Claude Code in any project.

## Topics

| File | Covers |
|------|--------|
| [stack.md](stack.md) | Common tech stack for riben.life / mingster.com / pstv |
| [nextjs.md](nextjs.md) | App Router patterns: data fetching rule, state-after-mutation, route-group layout gotcha, CRUD page pattern |
| [prisma.md](prisma.md) | BigInt epoch datetimes, serialize before client, no @prisma/client in client modules |
| [next-safe-action.md](next-safe-action.md) | Two-file convention, action clients, storeId bound-arg rule, SafeError, checklist |
