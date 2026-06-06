---
name: obsidian-vault
description: Search, create, and manage notes in the Obsidian vault. Use when the user wants to find, create, or organize notes in Obsidian, or when fetching cross-project tech patterns and project architecture docs on demand.
---

# Obsidian Vault

## Vault location

`~/Documents/Obsidian`

MCP server `obsidian` is configured in Claude Code settings and available in every session.

## Role in the context system

The vault is the **on-demand knowledge layer**. It is not loaded at session start — fetch notes
only when the task needs them. This keeps the working context small.

| Tier | What lives there | How loaded |
|------|-----------------|------------|
| Project `AGENTS.md` | Project-specific commands, constraints, architecture | Always (auto at session start) |
| `~/.claude/notes/` | Short cross-project rules and gotchas (source text) | On demand via `@`-include or MCP |
| **Obsidian vault** | Tech notes (linked index), project docs, ADRs, memory | **On demand via MCP** |

### Entry points

- **`Projects Index.md`** — all active projects with links to their pages
- **`Tech Notes Index.md`** — cross-project patterns (stack, Next.js, Prisma, server actions)
- **`Skills Index.md`** — available Claude Code skills

### When to fetch from Obsidian

- Before working on a domain you haven't touched in this session (architecture, payment, auth)
- When the project AGENTS.md says "see Obsidian for deeper context"
- When the user asks about past decisions or architecture rationale
- To write a session note or ADR after completing significant work

## Naming conventions

- **Title Case** for all file names (e.g., `Riben Life.md`, `Tech Notes/Next Js.md`)
- Index notes aggregate related topics with `[[wikilinks]]`
- Subfolders for project doc sets (`Riben Life Docs/`) and shared notes (`Tech Notes/`)

## Linking

Use `[[wikilinks]]` syntax. Notes link to dependencies at the bottom. Index notes are lists of wikilinks.

## MCP tools

The `obsidian` MCP server is the preferred interface:

```
read_file_content   — read a note by path
search_files        — search by filename or content keyword
list_recent_files   — see recently modified notes
create_file         — create a new note
```

Path format: relative to vault root, e.g. `Tech Notes/Prisma.md`, `Riben Life Docs/HOME.md`.

## Shell fallback

```bash
VAULT="$HOME/Documents/Obsidian"
find "$VAULT" -name "*.md" | grep -i "keyword"   # search by filename
grep -rl "keyword" "$VAULT" --include="*.md"       # search by content
find "$VAULT" -name "*Index*"                      # find all index notes
```

## Workflows

### Fetch cross-project tech patterns

```
read_file_content("Tech Notes Index.md")          # see what's available
read_file_content("Tech Notes/Next Js.md")        # fetch a specific note
```

Or read the source directly: `@~/.claude/notes/nextjs.md`

### Look up a project

```
read_file_content("Projects Index.md")            # list all projects
read_file_content("Riben Life.md")                # project overview + links to deep docs
read_file_content("Riben Life Docs/HOME.md")      # full doc index for riben.life
```

### Save a session note or ADR

1. Create a note using Title Case: e.g., `Riben Life Auth Fix.md`
2. Add `[[wikilinks]]` to related notes at the bottom
3. Reference it from the relevant project page or index note

### Add a new project

1. Create `Project Name.md` with stack, key paths, commands, architecture summary
2. Add it to `Projects Index.md`
3. Add an entry to the relevant tech notes' "See also" sections
