#!/usr/bin/env bash
# Guard: python is resolved through PATH (asdf shim), never a hardcoded interpreter.
# Fails on a python shebang other than "#!/usr/bin/env python3", and on an absolute
# python3 path or python3.NN used as a command. Comments do not count. Skips _outdated/ and *.md.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
self=script/tests/no-hardcoded-interpreter.test.sh

# scan <repo>: print file:line:text for each offender in the repo's tracked files.
scan() {
  (
    cd "$1" || exit 1
    spec=(-- . ':(exclude)_outdated' ':(exclude)*.md' ":(exclude)$self")
    git grep -nIE '^#!.*python' "${spec[@]}" 2>/dev/null \
      | grep -E '^[^:]+:1:' | grep -vE ':1:#! ?/usr/bin/env python3$'
    git grep -nIE '(^|[^[:alnum:]_./-])(/usr/bin/|/usr/local/bin/|/opt/homebrew/bin/)python3|(^|[^[:alnum:]_./-])python3\.[0-9]+([^[:alnum:]_.]|$)' "${spec[@]}" 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
  )
}

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got $2, want $3)"; fails=$((fails + 1)); fi; }

# Self-test on a planted fixture.
fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
(
  cd "$fx" && git init -q . && mkdir _outdated
  printf '#!/usr/bin/env python3\nprint(1)\n' > good.py
  printf '#!/usr/bin/python3\nprint(1)\n' > bad-shebang.py
  printf '#!/usr/bin/env python3.12\n' > bad-versioned.py
  printf '#!/bin/sh\n# layout python python3.10\n# /usr/bin/python3 in a comment\nx=1\n' > comments.sh
  printf '#!/bin/sh\n/opt/homebrew/bin/python3 run.py\n' > bad-cmd.sh
  printf '#!/bin/sh\nexec python3.11 -m venv v\n' > bad-ver-cmd.sh
  printf '#!/usr/bin/python3\n' > _outdated/old.py
  printf '/usr/local/bin/python3\n' > notes.md
  git add -A
)
out=$(scan "$fx")
check "fixture: python shebang flagged"   "$(echo "$out" | grep -c '^bad-shebang.py:1:')" 1
check "fixture: versioned shebang flagged" "$(echo "$out" | grep -c '^bad-versioned.py:1:')" 1
check "fixture: absolute command flagged"  "$(echo "$out" | grep -c '^bad-cmd.sh:2:')" 1
check "fixture: python3.NN command flagged" "$(echo "$out" | grep -c '^bad-ver-cmd.sh:2:')" 1
check "fixture: nothing else flagged"      "$(echo "$out" | grep -c .)" 4

# The repo itself.
hits=$(scan "$root")
if [ -n "$hits" ]; then
  echo "FAIL hardcoded interpreter found:"; echo "$hits" | cut -c1-160
  fails=$((fails + 1))
else
  echo "ok   no hardcoded interpreter in tracked files"
fi
echo "$fails failed"
[ "$fails" -eq 0 ]
