---
name: learning_memory
description: Record and retrieve persistent learnings or memory about frameworks, schemas, and best practices. Use when saving a codebase learning, when noting a solution, or when querying persistent notes.
---

# Learning Memory

Use this skill to persist codebase learnings and look up previous notes.

## Quick Start

### Recording a Learning
Run the contribute-to-agents script with a topic and note:
```bash
~/dotfiles/script/contribute-to-agents.sh <topic> "<note>"
```

### Retrieving Learnings
Search or view files in the notes directory:
```bash
grep -rn "search term" ~/dotfiles/.agents/claude/notes/
```

## Workflows

### 1. Registering a New Learning
When you discover a tricky issue, solve a complex configuration, or align on a pattern:
1. Choose a lowercase canonical topic name (for example, `nextjs` or `prisma`).
2. Construct a concise learning description without dashes as punctuation.
3. Propose running the command:
   ```bash
   ~/dotfiles/script/contribute-to-agents.sh <topic> "<note>"
   ```
4. Inform the user of the updated file location so they can commit it if desired.

### 2. Looking Up Learnings
Before writing code or configuring frameworks:
1. Search the local notes folder (`~/dotfiles/.agents/claude/notes/`) for relevant topics.
2. Read the corresponding note file using the file viewing tools.
