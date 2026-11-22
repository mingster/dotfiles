#!/usr/bin/env bash
# install_java_dev.sh compares whole versions: openjdk-21.0.1 does not count as openjdk-21 (#1571).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
cat >"$fake/asdf" <<'STUB'
#!/usr/bin/env bash
echo "asdf $*" >>"$FAKE_LOG"
case "$1 ${2:-}" in
  "plugin list") echo java ;;
  "list java") printf '  %s\n' $FAKE_INSTALLED ;;
esac
STUB
for c in brew java yay; do printf "#!/bin/sh\nexit 0\n" >"$fake/$c"; done
chmod +x "$fake"/*
run() {
  : >"$fake/log"
  HOME="$fake" FAKE_LOG="$fake/log" FAKE_INSTALLED="$1" PATH="$fake:/usr/bin:/bin" bash "$here/install_java_dev.sh" >/dev/null 2>&1 || true
}
run "openjdk-21.0.1 openjdk-210"
grep -q '^asdf install java openjdk-21$' "$fake/log" || { echo "FAIL near-miss skipped install"; cat "$fake/log"; exit 1; }
run "openjdk-21"
! grep -q '^asdf install java' "$fake/log" || { echo "FAIL exact version reinstalled"; cat "$fake/log"; exit 1; }
echo "PASS: 2 cases"
