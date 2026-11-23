#!/usr/bin/env bash
# Every script/*.sh|py|ts is named in a doc (README.md, AGENTS.md, docs/, .github/, templates/agent-team/docs/) (#1600).
# A script that is only a test helper or an example goes on the exempt list below, with the reason.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root" || exit 1

# Exempt by name (no doc needed): *.test.* files and test_setup.sh (a test wrapper), skipped in the loop below. Add
# `name.sh  # reason` lines here for other helpers and examples.
exempt='
'
exempt_names=$(printf '%s' "$exempt" | sed 's/#.*//' | tr -s ' \n' '\n\n')

docs=()
for d in README.md AGENTS.md docs .github templates/agent-team/docs; do [ -e "$d" ] && docs+=("$d"); done
missing=()
for f in script/*.sh script/*.py script/*.ts; do
  [ -f "$f" ] || continue
  name=${f#script/}
  case "$name" in *.test.*|test_setup.sh) continue ;; esac # tests and the test wrapper
  printf '%s\n' "$exempt_names" | grep -qxF "$name" && continue
  grep -rqF -- "$name" "${docs[@]}" || missing+=("$name")
done

if [ "${#missing[@]}" -eq 0 ]; then echo "ok   every script/ file is named in a doc"; exit 0; fi
echo "FAIL script/ files named in no doc (add a row to docs/agents/team-reference.md, or exempt them in this test):"
printf '  %s\n' "${missing[@]}"
exit 1
