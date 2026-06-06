#!/usr/bin/env bash
# contribute-to-agents.sh — add a reusable learning to the shared .agents knowledge base.
#
# Learnings are stored as dated entries in:
#   ~/dotfiles/.agents/claude/notes/<topic>.md
#
# That directory is linked into ~/.claude/notes/ at bootstrap, so any Claude Code session
# can load a note by adding an @ include to the project's CLAUDE.md or AGENTS.md:
#   @/Users/$USER/.claude/notes/<topic>.md
#
# Usage:
#   contribute-to-agents.sh <topic> ["note text"]   -- append inline note
#   contribute-to-agents.sh <topic>                  -- open $EDITOR for longer note
#
# After running, commit the updated note file to dotfiles to share across machines:
#   cd ~/dotfiles && git add .agents/claude/notes/<topic>.md && git commit -m "notes: <topic>"
#
# Examples:
#   contribute-to-agents.sh nextjs "Nested route-group layouts cause silent dev 404s"
#   contribute-to-agents.sh prisma "BigInt epoch fields need transformPrismaDataForJson before client"
#   contribute-to-agents.sh laravel  # opens $EDITOR
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
NOTES_DIR="$DOTFILES/.agents/claude/notes"

if [ $# -lt 1 ]; then
    printf 'Usage: %s <topic> ["note text"]\n' "$(basename "$0")" >&2
    printf '  topic: e.g. laravel, nextjs, docker\n' >&2
    exit 1
fi

TOPIC="$1"
NOTE_FILE="$NOTES_DIR/${TOPIC}.md"
TIMESTAMP="$(date '+%Y-%m-%d')"

mkdir -p "$NOTES_DIR"

# Initialize file with a header if new
if [ ! -f "$NOTE_FILE" ]; then
    printf '# %s\n' "$TOPIC" > "$NOTE_FILE"
fi

if [ $# -ge 2 ]; then
    NOTE_TEXT="$2"
    printf '\n## %s\n\n%s\n' "$TIMESTAMP" "$NOTE_TEXT" >> "$NOTE_FILE"
    printf 'Added to %s\n' "$NOTE_FILE"
else
    TMPFILE="$(mktemp)"
    printf '\n## %s\n\n# Write your note below. Lines starting with # are ignored.\n\n' "$TIMESTAMP" > "$TMPFILE"
    "${EDITOR:-vi}" "$TMPFILE"
    # Strip comment lines and collapse leading/trailing blank lines
    CONTENT="$(grep -v '^[[:space:]]*#' "$TMPFILE" | sed 's/^[[:space:]]*$//g' | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba;}')" || true
    if [ -n "$CONTENT" ]; then
        printf '\n## %s\n\n%s\n' "$TIMESTAMP" "$CONTENT" >> "$NOTE_FILE"
        printf 'Added to %s\n' "$NOTE_FILE"
    else
        printf 'Nothing added (empty note).\n'
    fi
    rm -f "$TMPFILE"
fi

printf '\nTo commit: cd %s && git add .agents/claude/notes/%s.md && git commit -m "notes: %s"\n' \
    "$DOTFILES" "$TOPIC" "$TOPIC"
