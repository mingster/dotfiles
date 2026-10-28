#!/usr/bin/env bash
# Guard: tests that change HOME keep the asdf shim working.
# 1. lib/asdf-pin.sh exports ASDF_DATA_DIR (asdf defaults it to $HOME/.asdf) and keeps a preset one.
# 2. Every test that assigns HOME to a temp dir sources lib/asdf-pin.sh (shell) or asdf_pin.py (python).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got $2, want $3)"; fails=$((fails + 1)); fi; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.asdf" "$tmp/other"

pinned() { # pinned <home> [preset ASDF_DATA_DIR]: print ASDF_DATA_DIR after sourcing the lib
  env -u ASDF_DATA_DIR ${2:+ASDF_DATA_DIR="$2"} HOME="$1" bash -c '. "$1"; printf "%s" "${ASDF_DATA_DIR:-}"' _ "$root/script/tests/lib/asdf-pin.sh"
}
check "lib: data dir from HOME/.asdf"      "$(pinned "$tmp/home")" "$tmp/home/.asdf"
check "lib: preset data dir kept"          "$(pinned "$tmp/home" "$tmp/other")" "$tmp/other"
check "lib: no asdf under HOME, none set"  "$(pinned "$tmp/other")" ""

py="$root/script/tests/lib/asdf_pin.py"
pypin() { env -u ASDF_DATA_DIR -u ASDF_PYTHON_VERSION HOME="$tmp/home" python3 -I -c '
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("asdf_pin", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.pin(); print(os.environ.get("ASDF_DATA_DIR", ""), os.environ.get("ASDF_PYTHON_VERSION", ""))' "$py"; }
want_py=$(awk '$1 == "python" { print $2 }' "$root/.tool-versions")
check "py lib: data dir and python pin"    "$(pypin 2>&1)" "$tmp/home/.asdf $want_py"

# Tests that assign HOME must source a pin helper. Stub-only tests are listed with the reason.
exempt=" script/tests/bootstrap-asdf-tools.test.sh script/tests/switch-login-shell-zsh.test.sh script/tests/asdf-pin-coverage.test.sh "
missing=""
while IFS= read -r f; do
  case "$exempt" in *" $f "*) continue ;; esac
  grep -qE '(^|[^A-Za-z_])HOME=("|\$|[a-z]|str|self)' "$root/$f" || continue
  grep -qE 'asdf-pin\.sh|asdf_pin' "$root/$f" || missing="$missing $f"
done < <(cd "$root" && git ls-files 'script/*.test.sh' 'script/tests/*.test.sh' 'script/tests/*.py')
check "every HOME-changing test pins asdf" "${missing:- none}" " none"
[ -z "$missing" ] || echo "unpinned:$missing" | tr ' ' '\n' | sed 's/^/  /'
echo "$fails failed"
[ "$fails" -eq 0 ]
