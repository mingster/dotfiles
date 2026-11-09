#!/usr/bin/env bash
# Tests for script/checks-local.sh: on a fixture diff it selects the same tests as the
# script-tests job (select-changed-script-tests.sh on the diff file list).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
r="$tmp/repo"
mkdir -p "$r/script/tests/lib"
cp "$src/script/checks-local.sh" "$src/script/select-changed-script-tests.sh" "$r/script/"
cp "$src/script/tests/lib/asdf-pin.sh" "$r/script/tests/lib/"
git -C "$r" init -q -b main
git -C "$r" -c user.email=t@t -c user.name=t add -A
git -C "$r" -c user.email=t@t -c user.name=t commit -qm base
git -C "$r" checkout -qb topic
printf '#!/usr/bin/env bash\n' >"$r/script/foo.sh"
printf '#!/usr/bin/env bash\n' >"$r/script/tests/foo.test.sh"
printf '#!/usr/bin/env bash\n' >"$r/script/tests/bar.test.sh"
git -C "$r" add -A
git -C "$r" -c user.email=t@t -c user.name=t commit -qm change

got=$(bash "$r/script/checks-local.sh" --list-only --base main 2>&1)
want=$(bash "$r/script/select-changed-script-tests.sh" --list-only \
  script/foo.sh script/tests/bar.test.sh script/tests/foo.test.sh 2>&1)
if [ -n "$got" ] && [ "$got" = "$want" ]; then
  echo "ok: selection matches the workflow's"
else
  echo "FAIL: selection differs"; echo "got:"; echo "$got"; echo "want:"; echo "$want"; fail=1
fi

[ "$fail" -eq 0 ]
