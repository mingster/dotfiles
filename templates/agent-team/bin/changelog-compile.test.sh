#!/usr/bin/env bash
# Tests for bin/changelog-compile.sh. Run: bash bin/changelog-compile.test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")" && pwd)/changelog-compile.sh"
fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

new_repo() {
  d="$(mktemp -d)"
  mkdir -p "$d/changelog.d"
  printf '# Changelog\n\n## [Unreleased] - 2026-10-01\n\n### Fixed\n- old\n' > "$d/CHANGELOG.md"
  echo "$d"
}
run() { (cd "$1" && bash "$SCRIPT" 2>&1); }

# 1. no fragments: no change, exit 0
d="$(new_repo)"; before="$(cat "$d/CHANGELOG.md")"
run "$d" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$before" = "$(cat "$d/CHANGELOG.md")" ] && pass "no fragments" || bad "no fragments"

# 2. two fragments land in file name order under the heading, then are deleted
d="$(new_repo)"
printf -- '- from b\n' > "$d/changelog.d/20-b.md"
printf -- '- from a\n' > "$d/changelog.d/10-a.md"
run "$d" >/dev/null; rc=$?
got="$(sed -n 3,7p "$d/CHANGELOG.md" | tr '\n' '|')"
[ "$rc" -eq 0 ] && [ "$got" = "## [Unreleased] - 2026-10-01|- from a|- from b||### Fixed|" ] \
  && [ ! -e "$d/changelog.d/10-a.md" ] && [ ! -e "$d/changelog.d/20-b.md" ] \
  && pass "two fragments order" || bad "two fragments order: $got"
# idempotent: second run changes nothing
snap="$(cat "$d/CHANGELOG.md")"; run "$d" >/dev/null
[ "$snap" = "$(cat "$d/CHANGELOG.md")" ] && pass "idempotent" || bad "idempotent"

# 3. missing heading: exit 1 with message, fragments kept
d="$(new_repo)"; printf '# Changelog\n' > "$d/CHANGELOG.md"
printf -- '- x\n' > "$d/changelog.d/1-x.md"
out="$(run "$d")"; rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q 'Unreleased' && [ -e "$d/changelog.d/1-x.md" ] \
  && pass "missing heading" || bad "missing heading"

# 4. README skipped and kept
d="$(new_repo)"; printf 'about\n' > "$d/changelog.d/README.md"
run "$d" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ -e "$d/changelog.d/README.md" ] && ! grep -q about "$d/CHANGELOG.md" \
  && pass "README skipped" || bad "README skipped"

# 5. -h and --help print usage to stdout, exit 0, touch nothing; any other argument exits 2 with usage on stderr
for arg in -h --help; do
  d="$(new_repo)"; printf -- '- x\n' > "$d/changelog.d/1-x.md"; before="$(cat "$d/CHANGELOG.md")"
  out="$(cd "$d" && bash "$SCRIPT" "$arg" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && echo "$out" | grep -q '^Usage:' && [ -e "$d/changelog.d/1-x.md" ] && [ "$before" = "$(cat "$d/CHANGELOG.md")" ] \
    && pass "$arg prints usage, changes nothing" || bad "$arg prints usage, changes nothing"
done
for arg in --hlep -x extra; do
  d="$(new_repo)"; printf -- '- x\n' > "$d/changelog.d/1-x.md"; before="$(cat "$d/CHANGELOG.md")"
  out="$(cd "$d" && bash "$SCRIPT" "$arg" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 2 ] && echo "$out" | grep -q '^Usage:' && [ -e "$d/changelog.d/1-x.md" ] && [ "$before" = "$(cat "$d/CHANGELOG.md")" ] \
    && pass "$arg exits 2, changes nothing" || bad "$arg exits 2, changes nothing"
done
d="$(new_repo)"; printf -- '- x\n' > "$d/changelog.d/1-x.md"
out="$(cd "$d" && bash "$SCRIPT" -h extra 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && [ -e "$d/changelog.d/1-x.md" ] && pass "-h with extra argument exits 2" || bad "-h with extra argument exits 2"
# 6. env vars still work with no argument
d="$(new_repo)"; mv "$d/CHANGELOG.md" "$d/CL.md"; mkdir "$d/frags"; printf -- '- env\n' > "$d/frags/1.md"
(cd "$d" && CHANGELOG=CL.md FRAGMENTS_DIR=frags bash "$SCRIPT" >/dev/null); rc=$?
[ "$rc" -eq 0 ] && grep -q -- '- env' "$d/CL.md" && [ ! -e "$d/frags/1.md" ] && pass "env vars honored" || bad "env vars honored"

exit "$fail"
