# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased] — 2026-09-03

### Added
- `AGENTS.md` single-source convention: `AGENTS.md` at the repo root, `CLAUDE.md` a one-line `@AGENTS.md` pointer, area-specific content in `docs/agents/<topic>.md`
- `docs/agents/` docs: `agent-files.md`, `issue-tracker.md`, `triage-labels.md`, `domain.md`, `obsidian.md`
- `script/init-agent-project.sh` to scaffold `docs/agents/` per project for the engineering workflow skills
- Engineering workflow section in `.agents/claude/CLAUDE.md` (five-stage grill/spec/tickets/implement/review loop)

### Changed
- `script/setup-claude-code.sh` now copies `~/.claude/CLAUDE.md` instead of symlinking it (cowork sessions skip a symlinked global memory file)
- Root `CLAUDE.md` reduced to `@AGENTS.md`; architecture and conventions moved into `AGENTS.md`
- `.agents/claude/settings.json`: emptied `enabledPlugins` (removed the `mattpocock-skills` plugin, whose skills are all vendored under `.agents/skills/`, plus three stale entries)
- Trimmed the derivable `.agents/` directory tree from `AGENTS.md`

### Changed (earlier)
- `create-pr` skill now writes a CHANGELOG.md entry before committing, using Keep a Changelog format
