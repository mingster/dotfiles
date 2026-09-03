# Agent instruction files: the convention

How `AGENTS.md`, `CLAUDE.md`, and `docs/agents/` are laid out in every repo here, and why.
Read this before adding, moving, or growing an agent instruction file.

## Layout

| File | Contents |
|------|----------|
| `AGENTS.md` (repo root) | The single source. Everything an agent needs in every session. |
| `CLAUDE.md` (repo root) | Exactly one line: `@AGENTS.md` |
| `<subdir>/CLAUDE.md` | Exactly one line: `@../AGENTS.md` |
| `<subdir>/AGENTS.md` | Symlink to `../AGENTS.md` |
| `docs/agents/*.md` | Everything that only matters in one area. Loaded on demand. |

`AGENTS.md` is canonical because Codex, Cursor, Copilot, Gemini CLI, Zed and others read it.
`CLAUDE.md` exists because Claude Code reads `CLAUDE.md` and **not** `AGENTS.md`, so without the
pointer file Claude sees nothing.

Use the `@AGENTS.md` import rather than `ln -s AGENTS.md CLAUDE.md`. Both work, but the import
lets you add Claude-only lines under it, and symlinks need Administrator or Developer Mode on
Windows.

## Size

Target under 200 lines. `AGENTS.md` is loaded into context at the start of every session, and
adherence drops as it grows. `/doctor` proposes trims for an oversized file.

Splitting into more `@` imports does **not** help: imported files load at launch too. Only two
things actually reduce what a session pays for:

1. Moving content to `docs/agents/<topic>.md` behind a pointer (cross tool, agent chooses to read)
2. Moving content to `.claude/rules/<topic>.md` with `paths:` frontmatter (Claude only, loads
   automatically when a matching file is touched)

Default to option 1 so Cursor and Codex keep seeing it. Reach for option 2 only when a rule is
being ignored and the automatic trigger is worth losing cross tool visibility.

## What belongs where

Keep in `AGENTS.md`: workspace layout, commands, constraints that are always true, pitfalls that
differ from tool defaults, and pointers to everything else.

Move to `docs/agents/`: patterns that apply to one kind of code (CRUD pages, data fetching,
logging, i18n), subsystem internals, and long reference tables.

Do not write at all: anything an agent can read off the codebase (directory listings, dependency
lists, architecture the file tree already shows), and accumulated session learnings. Auto memory
in `~/.claude/projects/<project>/memory/` owns learnings now, so hand-maintained "Learned facts"
sections are duplicated context.

## Pointer wording decides whether it gets read

A pointer's wording, not its target, decides how reliably an agent follows it. Name the trigger
condition:

- Good: "Read `docs/agents/conventions.md` before adding an admin CRUD page or writing a log line."
- Weak: "See `docs/agents/conventions.md` for more details."

## The global file is copied, not linked

`~/.claude/CLAUDE.md` is a **copy** of `.agents/claude/CLAUDE.md`, written by
`script/setup-claude-code.sh`. It cannot be a symlink: Cowork sessions skip a `~/.claude/CLAUDE.md`
that is a symlink or hard link, and skip user scope imports that resolve outside the session
working directory, so a linked or `@`-imported global file silently fails to load there.

The cost is drift. Edit `.agents/claude/CLAUDE.md` and re-run `bash script/setup-claude-code.sh`.
Never edit `~/.claude/CLAUDE.md` directly.

## New repos

`script/init-agent-project.sh` creates the `docs/agents/` config and the `## Agent skills` block,
and creates `AGENTS.md` plus the `CLAUDE.md` pointer when the repo has neither.

Reference: [Claude Code memory docs](https://code.claude.com/docs/en/memory)
