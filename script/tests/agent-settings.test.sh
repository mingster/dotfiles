#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" DOTFILES="$ROOT"
export XDG_CONFIG_HOME="$HOME/.config"
export AGENT_PRIVATE_BACKUP_MANIFEST="$TEST_ROOT/manifest"
mkdir -p "$HOME/.cursor" "$HOME/bin"
printf '#!/bin/sh\nexit 99\n' > "$HOME/bin/gh"
chmod +x "$HOME/bin/gh"
export PATH="$HOME/bin:$PATH"
printf '{}\n' > "$HOME/.cursor/mcp.json"
if bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out" 2>&1; then
  echo 'FAIL: unmanaged MCP settings accepted'; exit 1
fi
grep -q 'UNMANAGED .cursor/mcp.json' "$TEST_ROOT/out"
echo 'PASS: unmanaged settings fail coverage check without running provider CLIs'
printf '# private settings\nsettings/cursor-mcp.json $HOME/.cursor/mcp.json\n' > "$AGENT_PRIVATE_BACKUP_MANIFEST"
bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out"
grep -q 'OK private backup .cursor/mcp.json' "$TEST_ROOT/out"
echo 'PASS: private manifest expands HOME and covers an exact file'
cp "$ROOT/ide/cursor/cli-config.json" "$HOME/.cursor/cli-config.json"
bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out"
grep -q 'OK tracked settings .cursor/cli-config.json' "$TEST_ROOT/out"
printf '{}\n' > "$HOME/.cursor/cli-config.json"
if bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out"; then
  echo 'FAIL: changed copy accepted as tracked'; exit 1
fi
grep -q 'UNMANAGED .cursor/cli-config.json' "$TEST_ROOT/out"
cp "$ROOT/ide/cursor/cli-config.json" "$HOME/.cursor/cli-config.json"
echo 'PASS: copies need to match the tracked source'
if AGENT_PRIVATE_BACKUP_MANIFEST= bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out"; then
  echo 'FAIL: missing manifest accepted private settings'; exit 1
fi
grep -q 'private backup manifest not configured' "$TEST_ROOT/out"
echo 'PASS: missing manifest leaves private files uncovered'
printf 'settings/cursor $HOME/.cursor\n' > "$AGENT_PRIVATE_BACKUP_MANIFEST"
bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out"
echo 'PASS: manifest supports directory entries'
mkdir -p "$HOME/.claude" "$HOME/.gemini"
for name in .claude/.credentials.json .gemini/oauth_creds.json .gemini/google_accounts.json; do
  mkdir -p "$HOME/$name"
done
bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out"
! grep -Eq 'auth.json|credentials|oauth_creds|google_accounts' "$TEST_ROOT/out"
echo 'PASS: authentication stores stay outside setting discovery'

# A public template must never contain a literal credential, even with no live settings.
fixture="$TEST_ROOT/repo"
mkdir -p "$fixture/script" "$fixture/ide/cursor"
cp "$ROOT/script/agent-settings-check.py" "$fixture/script/"
git -C "$fixture" init -q
printf '{"EXAMPLE_API_KEY": "fixture-only-value"}\n' > "$fixture/ide/cursor/mcp.json"
git -C "$fixture" add ide/cursor/mcp.json
if DOTFILES="$fixture" python3 -B "$fixture/script/agent-settings-check.py" > "$TEST_ROOT/out"; then
  echo 'FAIL: literal credential in tracked template accepted'; exit 1
fi
grep -q 'UNSAFE tracked settings ide/cursor/mcp.json' "$TEST_ROOT/out"
! grep -q 'fixture-only-value' "$TEST_ROOT/out"
echo 'PASS: literal credentials fail without disclosing values'
printf '{"HEADER": "sk-fixture-aaaaaaaaaaaaaaaaaaaaaaaa"}\n' > "$fixture/ide/cursor/mcp.json"
if DOTFILES="$fixture" python3 -B "$fixture/script/agent-settings-check.py" > "$TEST_ROOT/out"; then
  echo 'FAIL: key-like literal under an arbitrary setting accepted'; exit 1
fi
grep -q 'UNSAFE tracked settings ide/cursor/mcp.json' "$TEST_ROOT/out"
echo 'PASS: key-like values are rejected under arbitrary setting names'

# Restore standard CLI settings twice, without app installation or network.
for cli in cursor agy brew; do
  printf '#!/bin/sh\nexit 0\n' > "$HOME/bin/$cli"
  chmod +x "$HOME/bin/$cli"
done
export OSTYPE=linux-gnu
cursor_fixture="$TEST_ROOT/cursor-repo"
mkdir -p "$cursor_fixture/script" "$cursor_fixture/ide/cursor/hooks" "$cursor_fixture/ide/cursor/rules"
for name in link-cursor-user.sh link-cursor-hooks.sh; do
  cp "$ROOT/script/$name" "$cursor_fixture/script/"
done
for name in cli-config.json settings.json keybindings.json environment.json hooks.json; do
  cp "$ROOT/ide/cursor/$name" "$cursor_fixture/ide/cursor/"
done
printf '#!/bin/sh\nexit 0\n' > "$cursor_fixture/ide/cursor/hooks/example.sh"
for pass in 1 2; do
  bash "$ROOT/script/setup-claude-code.sh" > "$TEST_ROOT/restore-out"
  DOTFILES="$cursor_fixture" bash "$ROOT/script/setup-cursor.sh" >> "$TEST_ROOT/restore-out"
  bash "$ROOT/script/setup-antigravity.sh" >> "$TEST_ROOT/restore-out"
  bash "$ROOT/script/setup-orca.sh" >> "$TEST_ROOT/restore-out"
  cmp "$HOME/.claude/keybindings.json" "$ROOT/.agents/claude/keybindings.json"
  cmp "$HOME/.claude/CLAUDE.md" "$ROOT/.agents/claude/CLAUDE.md"
  cmp "$HOME/.cursor/cli-config.json" "$ROOT/ide/cursor/cli-config.json"
  cmp "$HOME/.gemini/settings.json" "$ROOT/.gemini/settings.json"
  cmp "$HOME/.gemini/antigravity-cli/settings.json" "$ROOT/.gemini/antigravity-cli/settings.json"
  cmp "$HOME/.orca/presets.json" "$ROOT/.orca/presets.json"
done
echo 'PASS: standard CLI setup restores settings idempotently in temp HOME'
mkdir -p "$XDG_CONFIG_HOME/Cursor/User" "$HOME/Library/Application Support/orca"
printf '{}\n' > "$XDG_CONFIG_HOME/Cursor/User/settings.local.json"
printf '{}\n' > "$HOME/Library/Application Support/orca/settings.json"
OSTYPE=linux-gnu bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out" || :
grep -q 'UNMANAGED .config/Cursor/User/settings.local.json' "$TEST_ROOT/out"
OSTYPE=darwin bash "$ROOT/script/setup-check.sh" --agent-settings-only > "$TEST_ROOT/out" || :
grep -q 'UNMANAGED Library/Application Support/orca/settings.json' "$TEST_ROOT/out"
echo 'PASS: macOS app support and Linux XDG settings are inventoried'
