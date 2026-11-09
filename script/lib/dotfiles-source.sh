# shellcheck shell=bash
# Refuse to wire the live home from anything but the main dotfiles checkout (#761).

# True when HOME sits under the temp dir, as every test HOME does.
test_home() {
  local home tmp
  home=$(cd "$HOME" && pwd -P) || return 1
  tmp=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || return 1
  case "$home" in "$tmp"/*) return 0 ;; esac
  return 1
}

# worktree_main <dir>: when <dir> is inside a linked git worktree, print the main checkout.
# A linked worktree keeps its git dir under the main checkout's .git/worktrees.
worktree_main() {
  local git_dir common_dir
  git_dir=$(cd "$1" && cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 1
  common_dir=$(cd "$1" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 1
  [ "$git_dir" != "$common_dir" ] || return 1
  dirname "$common_dir"
}

# require_main_dotfiles <caller> <source dir>
# Passes when the source is ~/dotfiles resolved and not a linked git worktree,
# or when HOME sits under the temp dir (tests).
require_main_dotfiles() {
  local caller=$1 src main
  test_home && return 0
  src=$(cd "$2" && pwd -P) || return 1
  if ! main=$(worktree_main "$src"); then
    main=$(cd "$HOME/dotfiles" 2>/dev/null && pwd -P) || main="$HOME/dotfiles"
    [ "$src" != "$main" ] || return 0
  fi
  echo "$caller: refusing to wire $HOME from $src; run it from the main checkout $main" >&2
  exit 1
}
