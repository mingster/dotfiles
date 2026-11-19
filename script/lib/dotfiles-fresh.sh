# shellcheck shell=bash
# Preflight for the entry scripts (#1211): bring the dotfiles checkout up to date before the script runs.
# Behind and clean: fast-forward and say so. Dirty, diverged or offline: one warning line, nothing is
# reset, stashed or discarded. Up to date: silent. Never fails the caller; output goes to stderr.
# Runs once per process tree. DOTFILES_DIR (default ~/dotfiles) names the checkout.

dotfiles_fresh() {
  [ -z "${DOTFILES_FRESH_DONE:-}" ] || return 0
  export DOTFILES_FRESH_DONE=1
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/session-sync.sh" --dotfiles-only >&2 || true
  return 0
}

dotfiles_fresh
