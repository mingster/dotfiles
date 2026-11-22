#!/usr/bin/env bash
# agent-team.sh check flags a project doc that names a /skill with no skill behind it, and names the
# replacement of a retired one (#1476). A clean project, built in commands, URL paths and file paths pass.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/script/agent-team.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
P="$TMP/scratch"
mkdir -p "$HOME" "$P"
git -C "$P" init -q
git -C "$P" remote add origin https://github.com/example/scratch.git

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

timeout 120 bash "$SCRIPT" machine >"$TMP/machine.log" 2>&1 || bad "machine failed: $(tail -3 "$TMP/machine.log")"
timeout 120 bash "$SCRIPT" project "$P" >"$TMP/project.log" 2>&1 || bad "project failed: $(tail -3 "$TMP/project.log")"

check() { timeout 120 bash "$SCRIPT" check "$P" >"$TMP/check.log" 2>&1; }

check && ok "a clean project exits 0" || bad "clean project failed: $(tail -3 "$TMP/check.log")"

mkdir -p "$P/docs"
cat >"$P/docs/notes.md" <<'DOC'
Run `/staging-review` before the staging gate.
DOC
if check; then bad "a doc naming /staging-review passes"; else
  grep -q 'notes.md:1: /staging-review' "$TMP/check.log" && grep -q 'swarm' "$TMP/check.log" \
    && ok "/staging-review fails check, names file, line and replacement" || bad "message lacks file, line or replacement: $(tail -3 "$TMP/check.log")"
fi

printf 'Start with /crew, then /wrap-up and /team-grill-backlog.\n' >"$P/docs/notes.md"
check; out=$(cat "$TMP/check.log")
for n in crew wrap-up team-grill-backlog; do
  printf '%s' "$out" | grep -q "/$n" && ok "retired /$n is reported" || bad "retired /$n not reported"
done

printf 'Run /nonesuch now.\n' >"$P/docs/notes.md"
if check; then bad "an unknown /nonesuch passes"; else grep -q '/nonesuch' "$TMP/check.log" && ok "an unknown skill name is reported" || bad "unknown name not reported"; fi

printf 'Run /staging-review now.\n' >"$P/.claude/notes.md"
printf 'Fine.\n' >"$P/docs/notes.md"
check; grep -q '\.claude/notes.md:1: /staging-review' "$TMP/check.log" && ok "a .claude file is scanned" || bad "a .claude file is not scanned"
rm "$P/.claude/notes.md"

printf 'Run /staging-review now.\n' >>"$P/AGENTS.md"
check; grep -q 'AGENTS.md:[0-9]*: /staging-review' "$TMP/check.log" && ok "AGENTS.md is scanned" || bad "AGENTS.md is not scanned"
sed -i.bak '/staging-review/d' "$P/AGENTS.md" && rm "$P/AGENTS.md.bak"

cat >"$P/docs/notes.md" <<'DOC'
Built in: /help, /clear and /compact.
A URL: https://example.com/staging-review and http://host/crew.
A path: docs/agents/team.md, ./crew, ~/wrap-up and /tmp.
A named skill: /tdd and /mine.
A plugin skill: /plugin:thing.
DOC
printf 'Run /tdd, /staging-review.\nRun /help /crew now\n' >"$P/docs/notes.md"
check; grep -q 'notes.md:1: /staging-review' "$TMP/check.log" && grep -q 'notes.md:2: /crew' "$TMP/check.log" \
  && ok "a second name next to a valid one is reported" || bad "adjacent names missed: $(cat "$TMP/check.log")"
printf 'Built in: /help, /clear and /compact.\nA URL: https://example.com/staging-review and http://host/crew.\nA path: docs/agents/team.md, ./crew, ~/wrap-up and /tmp.\nA named skill: /tdd and /mine.\nA plugin skill: /plugin:thing.\n' >"$P/docs/notes.md"
mkdir -p "$P/.claude/skills/mine"
printf -- '---\nname: mine\n---\n' >"$P/.claude/skills/mine/SKILL.md"
check && ok "built in commands, URL paths, file paths and real skills pass" || bad "false positive: $(cat "$TMP/check.log")"

printf '%s\n' "sed -i 's/A = \"1\"/A = \"0\"/g' x" 'Context: /subtask and /fork.' 'Routes: /account, /api, /root and /snap.' 'Open /qr-generator in the browser.' >"$P/docs/notes.md"
check && ok "/subtask, sed /g and web routes pass" || bad "false positive: $(cat "$TMP/check.log")"
printf '%s\n' 'Keep it in `/shop`, and use the page at `/contact` or /liff on the site.' 'Skills live in `/srv/app` and the route /shop/[storeId] and https://x/unv.' 'Use the /order page when you run the app, then /about.' >"$P/docs/notes.md"
check && ok "a route in a skill or run sentence, not named as the command, passes (#1546)" || bad "route flagged: $(cat "$TMP/check.log")"
printf 'Run /nonesuch now, or run `/other`, or use /third, or the /fourth skill.\n' >"$P/docs/notes.md"
check; n=$(grep -c 'names no skill' "$TMP/check.log"); [ "$n" -eq 4 ] && ok "an unknown name right after run/use, or before skill, is still reported" || bad "expected 4 unknown names, got $n"
printf 'Run /staging-review now.\n' >"$P/docs/notes.md"
check || ok "a run-context unknown name still fails"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
