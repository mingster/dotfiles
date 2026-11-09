#!/usr/bin/env bash
# Run what .github/workflows/checks.yml runs, for the files this branch changed.
# Usage: checks-local.sh [--list-only] [--base <ref>]   (base defaults to origin/main)
# Same file selection as the script-tests job, then the shellcheck job. A temp HOME
# with the asdf pins keeps a test that forgets to pin asdf failing here, as it does in CI.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
base=origin/main
list_only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list-only) list_only=(--list-only); shift ;;
    --base) base=${2:?--base needs a ref}; shift 2 ;;
    *) echo "Usage: $0 [--list-only] [--base <ref>]" >&2; exit 2 ;;
  esac
done

# shellcheck source=tests/lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
cd "$root"
changed=()
while IFS= read -r f; do changed+=("$f"); done < <(git diff --diff-filter=d --name-only "$(git merge-base "$base" HEAD)")
HOME=$(mktemp -d)
export HOME
trap 'rm -rf "$HOME"' EXIT
bash script/select-changed-script-tests.sh ${list_only[@]+"${list_only[@]}"} "${changed[@]+"${changed[@]}"}"
[ "${#list_only[@]}" -eq 0 ] || exit 0
bash script/shellcheck-dotfiles.sh
