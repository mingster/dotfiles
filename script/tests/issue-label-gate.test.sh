#!/usr/bin/env bash
# Tests for issue-label-gate.sh: every open issue gets a state and a P label, board status labels follow the state.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../issue-label-gate.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "issue-label-gate.test.sh: skip, jq not on PATH" >&2; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[ "${GH_FAIL:-}" != 1 ] || exit 1
[ "$1 $2" != "issue list" ] || cat "$GH_ISSUES"
EOF
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log" GH_ISSUES="$tmp/issues.json"
run() { # [args...] ; sets out and ec
  : >"$GH_LOG"
  set +e
  out=$(PATH="$tmp/bin:$PATH" bash "$script" --repo acme/dots "$@" 2>"$tmp/err")
  ec=$?
  set -e
}
set -e
label_json() { # number label... -> one issue object
  local n=$1 l; shift
  l=$(printf '{"name":"%s"},' "$@"); l=${l%,}
  printf '{"number":%s,"labels":[%s]}' "$n" "$l"
}

# No labels at all: needs-triage and P2.
printf '[%s]\n' "$(label_json 1)" >"$GH_ISSUES"
run
[ "$ec" = 0 ] && ok || bad "dry run exits 0 ($ec)"
grep -Fxq '#1 +needs-triage +P2' <<<"$out" && ok || bad "unlabeled issue needs needs-triage and P2 ($out)"
grep -q 'issue edit' "$GH_LOG" && bad "dry run must not edit" || ok
run --apply
grep -Fxq 'issue edit 1 --repo acme/dots --add-label needs-triage,P2' "$GH_LOG" && ok || bad "apply should add both labels ($(cat "$GH_LOG"))"

# A state label without a P label gets P2 only; a P label without a state gets needs-triage only.
printf '[%s,%s]\n' "$(label_json 2 ready-for-agent status:接下來)" "$(label_json 3 P1)" >"$GH_ISSUES"
run
grep -Fxq '#2 +P2' <<<"$out" && ok || bad "ready issue without P gets P2 only ($out)"
grep -Fxq '#3 +needs-triage' <<<"$out" && ok || bad "P1 issue without state gets needs-triage ($out)"

# Every hold label and the in flight label count as a state.
printf '[%s,%s,%s,%s,%s]\n' "$(label_json 4 blocked P2)" "$(label_json 5 tracking P2)" "$(label_json 6 deferred P3)" \
  "$(label_json 7 status:進行中 P2)" "$(label_json 8 owner status:等你決定 P2)" >"$GH_ISSUES"
run
grep -q 'needs-triage' <<<"$out" && bad "a hold or in flight label is a state ($out)" || ok
grep -q 'issue-label-gate: .* ok' <<<"$out" && ok || bad "a fully labeled repo reports ok ($out)"

# In flight beats a leftover needs-triage or ready-for-agent.
printf '[%s,%s]\n' "$(label_json 9 needs-triage status:進行中 P2)" "$(label_json 10 ready-for-agent status:接下來 status:進行中 P2)" >"$GH_ISSUES"
run
grep -Fxq '#9 -needs-triage' <<<"$out" && ok || bad "needs-triage comes off an in flight issue ($out)"
grep -Fxq '#10 -ready-for-agent -status:接下來' <<<"$out" && ok || bad "ready-for-agent and next come off an in flight issue ($out)"

# Board status labels follow the state.
printf '[%s,%s,%s,%s]\n' "$(label_json 11 ready-for-agent P2)" "$(label_json 12 owner P2)" \
  "$(label_json 13 needs-triage status:接下來 P2)" "$(label_json 14 blocked status:等你決定 P2)" >"$GH_ISSUES"
run
grep -Fxq '#11 +status:接下來' <<<"$out" && ok || bad "a ready issue gets status:接下來 ($out)"
grep -Fxq '#12 +status:等你決定' <<<"$out" && ok || bad "an owner issue gets status:等你決定 ($out)"
grep -Fxq '#13 -status:接下來' <<<"$out" && ok || bad "a not ready issue loses status:接下來 ($out)"
grep -Fxq '#14 -status:等你決定' <<<"$out" && ok || bad "status:等你決定 goes when owner is gone ($out)"
printf '[%s]\n' "$(label_json 15 ready-for-agent blocked P2)" >"$GH_ISSUES"
run
grep -q 'status:接下來' <<<"$out" && bad "a held ready issue is not next ($out)" || ok

# A failed gh call never blocks work.
GH_FAIL=1 run --apply
[ "$ec" = 0 ] && ok || bad "a failed gh call exits 0 ($ec)"
grep -q 'could not list' "$tmp/err" && ok || bad "a failed list says so ($(cat "$tmp/err"))"
set +e
bash "$script" --bogus >/dev/null 2>&1
[ "$?" = 2 ] && ok || bad "an unknown flag exits 2"
set -e
echo "issue-label-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
