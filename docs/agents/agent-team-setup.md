# Agent team setup

Use `script/agent-team.sh` as the entry point for machine setup and project adoption.
The command composes the existing setup, adoption, tracker initialization, skill sync
and audit scripts. Run `script/agent-team.sh --help` for the supported commands.

```bash
script/agent-team.sh machine
script/agent-team.sh project /path/to/project --project-name acme
script/agent-team.sh reset /path/to/project
script/agent-team.sh reset /path/to/project --apply
script/agent-team.sh all /path/to/project
```

Machine setup configures Claude Code, Codex, Cursor, Antigravity, Orca and shared
skill links. Verification reports missing commands and owner login steps without
reading credential files. Missing owner prerequisites are warnings; a failed setup
script is an error. Use `--dry-run` to preview machine setup without running it.

Missing provider CLIs are installed once using `install_claude.sh`, the official
Cursor and Antigravity installers, and `npm install -g @openai/codex`. If npm is
missing, install Node.js and retry. Installer references:
[Claude Code](https://code.claude.com/docs/en/setup),
[Codex](https://help.openai.com/en/articles/11096431),
[Cursor](https://cursor.com/docs/cli/installation) and
[Antigravity](https://antigravity.google/docs/cli/install/).
Existing differing configuration files are moved to `<file>.bak.<date>` before
replacement. Usage gate and worker budget hooks are composed from the existing
Claude hook templates. Logins and credentials are never migrated or inspected.
Orca installation and sign in remain owner steps when its CLI is missing.

Project adoption runs `adopt-agent-team.sh`, `init-agent-project.sh --labels`,
`sync-team-skills.sh` and `team-audit.sh`. The owner or architect must fill in
`docs/agents/team-facts.md`, `docs/agents/deploy-facts.md` and
`docs/agents/domain.md`, then establish the project's domain context and deployment
commands. Label creation requires GitHub access. Audit findings remain visible and
return a failing status for review.

Reset defaults to a preview and requires a clean Git working tree, including
untracked files. `--apply` leaves changes uncommitted for review. Product facts,
domain context, ADRs and intents stay project owned. Customized role files are
preserved and reported for manual reconciliation when they cannot be safely
refreshed. Never put product facts in generated team skills.
Conflicts show only line counts, preserving the whole customized role. A saved
template hash permits safe refresh of roles that have no local edits. Existing
roles without a saved baseline are preserved whenever they differ. Reset also
refreshes the Token budget, Compact instructions and Owner context commands
sections in `AGENTS.md`, keeping other project instructions.

`all` configures the machine first, then selects project adoption or reset based on
the project's team files. Existing projects retain reset's preview default; use
`--apply` for an explicit reset. `all --dry-run` previews both stages.

The commands use the vendored skills already in dotfiles. Updating that snapshot
from upstream is a separate maintainer operation through
`script/sync-mattpocock-skills.sh`; project setup never refreshes upstream or
changes the dotfiles checkout. No command commits or pushes the target project.
