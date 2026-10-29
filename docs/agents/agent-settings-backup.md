# Agent settings backup and restore

Read this when adding an agent setting, restoring a machine, or investigating an
`UNMANAGED` line from `script/setup-check.sh`. Public templates contain portable
preferences only. Existing machine settings are never imported into this repo.

## Inventory

Paths below are relative to HOME on both macOS and Linux unless indicated.
`support` means `Library/Application Support` on macOS and
`${XDG_CONFIG_HOME:-$HOME/.config}` on Linux. Codex respects `CODEX_HOME`.

| Live settings | Public source and standard restore | Private coverage required for |
| --- | --- | --- |
| `.claude/CLAUDE.md`, `settings.json`, `keybindings.json` | `.agents/claude/`; `setup-claude-code.sh` copies instructions and links settings/keybindings | Copies that differ from the template, `settings.local.json`, other `settings*.json`, `.mcp.json` |
| `.codex/config.toml`, `AGENTS.md` | `.codex/`; `setup-codex.sh` renders HOME on first initialization, reconciles managed keys, links instructions | Custom config tables, other `config*.toml`, runtime `hooks.json` |
| `.cursor/cli-config.json`, `hooks.json` | `ide/cursor/`; `setup-cursor.sh` copies CLI config and installs hooks | Customized copies, other `cli-config*.json`, `mcp.json` |
| `.gemini/settings.json`, `antigravity-cli/settings.json` | `.gemini/`; `setup-antigravity.sh` copies/merges settings when the IDE is installed | Custom settings, `settings.local.json`, `GEMINI.md` |
| `.gemini/config/AGENTS.md`, `skills.json`, `hooks.json` | `setup-antigravity.sh` generates instructions/skills paths and merges hooks | Generated machine paths and runtime hooks; private restore or regeneration |
| `.orca/presets.json` | `.orca/`; `setup-orca.sh` copies presets | Custom presets, `settings*.json`, `config*.json` |
| `support/orca/{settings*,config*,preferences*}.json` | No public app profile: app configuration can mix machine paths and private data | Individually reviewed, sanitized settings files |
| `support/Claude/{claude_desktop_config,config}.json` | `setup-claude-desktop.sh` merges public `init/` defaults and preserves local values | Mixed Desktop preferences/MCP settings; sanitized private backup |
| `support/Cursor/User/{settings,keybindings,environment}.json` | `ide/cursor/`; `setup-cursor.sh` links settings or renders a local overlay | Customized copies and local overlays |
| `support/Antigravity IDE/User/{settings,keybindings}.json` | `ide/antigravity/`; `setup-antigravity.sh` links settings or renders a local overlay | Customized copies and local overlays |

The executable inventory is `script/agent-settings-check.py`. It checks explicit
setting names and setting/config filename families, including future local
overlays, without recursively walking app data. Add a new setting path there when
a CLI introduces one. Generated paths and merged files require private coverage
unless they exactly match a tracked template. Template existence alone does not
cover a modified live copy.

## Private manifest contract

Set `AGENT_PRIVATE_BACKUP_MANIFEST` to an external manifest. Each nonblank,
noncomment row is `<repo-path> <live-path>`; the first whitespace separates the
columns, so live paths may contain spaces. `$HOME` and `${HOME}` expand in the
live column. Live paths must be absolute after expansion. Directory entries
cover descendant settings, but prefer individual files for mixed app folders.
The checker reads only this metadata, never the private backup payloads.

Example rows for the private backup owner to adapt **outside this repo**:

```text
settings/claude-local.json $HOME/.claude/settings.local.json
settings/claude.json $HOME/.claude/settings.json
settings/claude-instructions.md $HOME/.claude/CLAUDE.md
settings/claude-keybindings.json $HOME/.claude/keybindings.json
settings/codex.toml $HOME/.codex/config.toml
settings/codex-hooks.json $HOME/.codex/hooks.json
settings/cursor-cli.json $HOME/.cursor/cli-config.json
settings/cursor-mcp.json $HOME/.cursor/mcp.json
settings/cursor-hooks.json $HOME/.cursor/hooks.json
settings/gemini.json $HOME/.gemini/settings.json
settings/antigravity-cli.json $HOME/.gemini/antigravity-cli/settings.json
settings/agent-hooks.json $HOME/.gemini/config/hooks.json
settings/agent-skills.json $HOME/.gemini/config/skills.json
```

List any other changed copy or app profile from the inventory after reviewing
its exclusion policy. Manifest membership means declared coverage; it does not
prove a backup was taken or that its restore works. Unset or missing manifests
print `private backup manifest not configured`; matching public files still
count as covered, while private settings fail coverage.

Never include credentials, sign-in state, keyrings, OAuth stores, `auth.json`,
`.credentials.json`, `oauth_creds.json`, `google_accounts.json`, app databases,
or whole app-data directories. `.claude.json` is mixed runtime/account state,
not a portable settings template. Keep it outside blanket backups. For mixed
MCP/settings files, the private backup owner must exclude API keys, bearer
tokens, passwords and secret-valued environment entries, using environment
references for restore instead. A manifest row is not a sanitizer.

## Restore and verify

1. Run the standard `install.sh` flow on the new machine. The matching setup
   scripts above restore public preferences. Claude keybindings start with an
   empty custom bindings list; applications retain their built-in defaults.
2. Restore reviewed, sanitized private settings through the private backup's
   restore workflow after public setup, preserving the HOME directory and XDG
   layout of the destination. Never restore authentication from backup; sign in
   through each app. Configure secret environment values separately.
3. Export the external manifest path and run `bash script/setup-check.sh`.
   For a settings-only, read-only check without provider commands, run
   `bash script/setup-check.sh --agent-settings-only`.
4. Resolve each `UNMANAGED` setting by restoring the public template or arranging
   sanitized private coverage. `UNSAFE tracked settings` blocks literal secret
   assignments in public agent JSON/TOML templates and prints only the filename.

This repository does not modify the private manifest or execute private backup
or restore jobs. Host inspection, credential rotation and a real private restore
drill remain owner tasks; temp-HOME tests prove local setup and audit behavior.
