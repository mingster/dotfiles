#!/usr/bin/env bash
# Compose machine setup and project adoption without duplicating their installers.
set -euo pipefail
DOTFILES="${DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export DOTFILES
export PATH="$HOME/.local/bin:$PATH"
usage() {
  cat <<'USAGE'
Usage: agent-team.sh machine [--dry-run]
       agent-team.sh project <dir> [--project-name <name>] [--dry-run]
       agent-team.sh reset <dir> [--project-name <name>] [--apply]
       agent-team.sh all <dir> [--project-name <name>] [--apply | --dry-run]

Reset previews by default, requires a clean Git root, and leaves changes uncommitted.
Machine setup installs missing CLIs, backs up differing settings, and reports login needed.
Project setup creates tracker labels and prints product facts to complete.
USAGE
}
die() { echo "agent-team: $*" >&2; exit 2; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
mode=${1:-}; [ $# -eq 0 ] || shift
case "$mode" in machine|project|reset|all) ;; *) usage >&2; exit 2 ;; esac
target=; name=; dry=0; apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project-name) [ $# -ge 2 ] && [ -n "$2" ] || die '--project-name needs a value'; name=$2; shift ;;
    --dry-run) dry=1 ;;
    --apply) apply=1 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$target" ] || die 'only one project directory is allowed'; target=$1 ;;
  esac
  shift
done
[ "$dry$apply" != 11 ] || die '--apply and --dry-run cannot be combined'
if [ "$mode" = machine ]; then
  [ -z "$target$name" ] && [ "$apply" -eq 0 ] || die 'machine accepts only --dry-run'
else
  [ -n "$target" ] && [ -d "$target" ] || die 'provide an existing project directory'
  target=$(cd "$target" && pwd -P)
  root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || die 'target must be a Git root'
  [ "$target" = "$(cd "$root" && pwd -P)" ] || die 'target must be a Git root'
fi
facts() {
  echo 'Owner or architect: complete docs/agents/team-facts.md, docs/agents/deploy-facts.md and docs/agents/domain.md.'
}
backup_setting() {
  local src=$1 dest=$2 backup suffix=0
  [ -e "$dest" ] || [ -L "$dest" ] || return 0
  [ -f "$src" ] || return 0
  cmp -s "$src" "$dest" && return 0
  backup="$dest.bak.$(date +%Y%m%dT%H%M%S)"
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    suffix=$((suffix + 1)); backup="$dest.bak.$(date +%Y%m%dT%H%M%S).$suffix"
  done
  mv "$dest" "$backup"
  echo "agent-team: backed up $dest to $backup"
}
machine() {
  local setup src user_dir rendered_settings=
  local setups=(install-agent-clis setup-agent-skills setup-claude-code setup-cursor setup-antigravity setup-orca setup-agent-hooks)
  if [ "$dry" -eq 1 ]; then
    for setup in "${setups[@]}"; do echo "[dry-run] machine: $setup.sh"; done
    echo '[dry-run] verify CLIs and report owner login needed; no settings or login files read.'
    return
  fi
  # The old bootstrap linked the whole directory. Move that link itself before
  # touching any children so its source and login files remain untouched.
  if [ -L "$HOME/.claude" ]; then
    backup_setting "$DOTFILES/.agents/claude/settings.json" "$HOME/.claude"
  fi
  if [ -f "$DOTFILES/.agents/claude/settings.json" ]; then
    rendered_settings=$(mktemp)
    bash "$DOTFILES/script/setup-agent-hooks.sh" --render "$DOTFILES/.agents/claude/settings.json" > "$rendered_settings"
    backup_setting "$rendered_settings" "$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"
    if ! cmp -s "$rendered_settings" "$HOME/.claude/settings.json"; then
      cp "$rendered_settings" "$HOME/.claude/settings.json"
    fi
    rm -f "$rendered_settings"
  fi
  # Back up only configuration paths owned by the composed installers. Never read
  # auth.json, credentials, local MCP settings, environment files or login state.
  for src in "$DOTFILES/.agents/claude"/*; do
    [ -f "$src" ] || continue
    case "$(basename "$src")" in README.md|settings.json) continue ;; esac
    backup_setting "$src" "$HOME/.claude/$(basename "$src")"
  done
  for src in "$DOTFILES/ide/cursor/hooks"/*.sh; do
    [ -f "$src" ] || continue
    backup_setting "$src" "$HOME/.cursor/hooks/$(basename "$src")"
  done
  backup_setting "$DOTFILES/ide/cursor/cli-config.json" "$HOME/.cursor/cli-config.json"
  backup_setting "$DOTFILES/ide/cursor/hooks.json" "$HOME/.cursor/hooks.json"
  backup_setting "$DOTFILES/.orca/presets.json" "$HOME/.orca/presets.json"
  backup_setting "$DOTFILES/.gemini/settings.json" "$HOME/.gemini/settings.json"
  backup_setting "$DOTFILES/.gemini/antigravity-cli/settings.json" "$HOME/.gemini/antigravity-cli/settings.json"
  backup_setting "$DOTFILES/.agents/claude/CLAUDE.md" "$HOME/.gemini/config/AGENTS.md"
  rendered_settings=$(mktemp)
  cat > "$rendered_settings" <<EOF
{
  "entries": [
    { "path": "$DOTFILES/.agents/skills" }
  ]
}
EOF
  backup_setting "$rendered_settings" "$HOME/.gemini/config/skills.json"
  rm -f "$rendered_settings"
  case "${OSTYPE:-}" in
    darwin*) user_dir="$HOME/Library/Application Support" ;;
    *) user_dir="${XDG_CONFIG_HOME:-$HOME/.config}" ;;
  esac
  for src in settings.json keybindings.json environment.json; do
    backup_setting "$DOTFILES/ide/cursor/$src" "$user_dir/Cursor/User/$src"
  done
  for src in settings.json keybindings.json; do
    backup_setting "$DOTFILES/ide/antigravity/$src" "$user_dir/Antigravity IDE/User/$src"
  done
  for setup in "${setups[@]}"; do
    if [ "$setup" = setup-claude-code ] && [ -f "$DOTFILES/.agents/claude/settings.json" ]; then
      bash "$DOTFILES/script/$setup.sh" --keep-settings
    else
      bash "$DOTFILES/script/$setup.sh"
    fi
  done
  for setup in claude orca python3 git; do
    if command -v "$setup" >/dev/null 2>&1; then echo "verify: $setup available";
    else echo "WARN verify: missing CLI $setup"; fi
  done
  if command -v agent >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1; then echo 'verify: Cursor agent available';
  else echo 'WARN verify: missing CLI Cursor agent'; fi
  if command -v agy >/dev/null 2>&1; then echo 'verify: Antigravity agy available';
  else echo 'WARN verify: missing CLI Antigravity agy'; fi
  echo 'login needed: owner must verify Claude Code, Cursor agent and Antigravity sign-in in each CLI; login state was not inspected.'
}
project() {
  [ ! -d "$target/.claude/agents" ] && [ ! -f "$target/.claude/model-routing.md" ] || die 'existing agent team: use reset'
  local args=("$target") status=0
  [ -z "$name" ] || args+=(--project-name "$name")
  [ "$dry" -eq 0 ] || args+=(--dry-run)
  bash "$DOTFILES/script/adopt-agent-team.sh" "${args[@]}"
  local init_args=(--labels)
  [ "$dry" -eq 0 ] || init_args+=(--dry-run)
  bash "$DOTFILES/script/init-agent-project.sh" "${init_args[@]}" "$target"
  if [ "$dry" -eq 0 ]; then
    bash "$DOTFILES/script/sync-team-skills.sh" "$target"
    bash "$DOTFILES/script/team-audit.sh" "$target" || status=$?
  fi
  facts
  return "$status"
}
reset() {
  [ -z "$(git -C "$target" status --porcelain --untracked-files=all)" ] || die 'reset requires a clean working tree; no files changed'
  local args=(--reset) status=0
  [ -z "$name" ] || args+=(--project-name "$name")
  if [ "$apply" -eq 0 ]; then
    echo "agent-team: reset preview for $target (use --apply to write)"
    args+=(--dry-run)
    bash "$DOTFILES/script/adopt-agent-team.sh" "${args[@]}" "$target"
    bash "$DOTFILES/script/init-agent-project.sh" --dry-run "$target"
    bash "$DOTFILES/script/sync-team-skills.sh" --check "$target" || status=$?
    [ "$status" -le 1 ] || return "$status"
    status=0
  else
    bash "$DOTFILES/script/adopt-agent-team.sh" "${args[@]}" "$target"
    bash "$DOTFILES/script/init-agent-project.sh" "$target"
    bash "$DOTFILES/script/sync-team-skills.sh" "$target"
    echo 'agent-team: changes are uncommitted; review with git diff and git status.'
    bash "$DOTFILES/script/team-audit.sh" "$target" || status=$?
  fi
  facts
  return "$status"
}
case "$mode" in
  machine) machine ;;
  project) [ "$apply" -eq 0 ] || die '--apply is only for reset'; project ;;
  reset) reset ;;
  all)
    if [ -d "$target/.claude/agents" ] || [ -f "$target/.claude/model-routing.md" ]; then
      [ -z "$(git -C "$target" status --porcelain --untracked-files=all)" ] || die 'reset requires a clean working tree; no files changed'
      action=reset
    else
      [ "$apply" -eq 0 ] || die '--apply is only for existing projects'
      action=project
    fi
    bash "$DOTFILES/script/adopt-agent-team.sh" --check-paths "$target"
    machine
    "$action"
    ;;
esac
