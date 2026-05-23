---
name: obsidian-vault
description: Search, create, and manage notes in the Obsidian vault with wikilinks and index notes. Use when user wants to find, create, or organize notes in Obsidian.
---

# Obsidian Vault

## Vault location

`~/Documents/Obsidian`

Mostly flat at root level.

## Naming conventions

- **Index notes**: aggregate related topics (e.g., `Claude Index.md`, `Skills Index.md`, `Projects Index.md`)
- **Title case** for all note names
- No folders for organization — use links and index notes instead

## Linking

- Use Obsidian `[[wikilinks]]` syntax: `[[Note Title]]`
- Notes link to dependencies/related notes at the bottom
- Index notes are just lists of `[[wikilinks]]`

## MCP tools (preferred)

The `obsidian` MCP server is configured in Claude Code settings. Prefer MCP tools over shell commands when available:

- `read_file` — read a note by path
- `write_file` — create or overwrite a note
- `list_directory` — list vault contents
- `search_files` — search by filename or content

## Shell fallback

```bash
VAULT="$HOME/Documents/Obsidian"

# Search by filename
find "$VAULT" -name "*.md" | grep -i "keyword"

# Search by content
grep -rl "keyword" "$VAULT" --include="*.md"

# Find index notes
find "$VAULT" -name "*Index*"

# Find backlinks
grep -rl "\[\[Note Title\]\]" "$VAULT" --include="*.md"
```

## Workflows

### Create a new note

1. Use **Title Case** for filename
2. Write content as a self-contained unit
3. Add `[[wikilinks]]` to related notes at the bottom

### Save agent memory

Create a note named after the topic (e.g., `Project Foo Context.md`). Reference it from the relevant index note. Agents write here to persist context across sessions.
