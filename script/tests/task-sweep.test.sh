#!/usr/bin/env bash
# Tests for task-sweep.sh: a blocked or failed task whose issue is closed becomes completed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../task-sweep.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "task-sweep.test.sh: skip, jq not on PATH" >&2; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/tasks.json" <<'EOF'
{"ok":true,"result":{"tasks":[
 {"id":"t_blocked_closed","status":"blocked","task_title":"#10|fullstack-dev","spec":"Refs acme/dots#10\n\n# build"},
 {"id":"t_failed_closed","status":"failed","task_title":"verify","spec":"Refs #11\n\n# verify"},
 {"id":"t_blocked_open","status":"blocked","task_title":"#12|fullstack-dev","spec":"Refs acme/dots#12\n\n# build"},
 {"id":"t_done","status":"completed","task_title":"#10|qa-sdet","spec":"Refs acme/dots#10"},
 {"id":"t_other_repo","status":"blocked","task_title":"#10|fullstack-dev","spec":"Refs acme/app#10"},
 {"id":"t_missing","status":"failed","task_title":"#9999|fullstack-dev","spec":"Refs #9999"},
 {"id":"t_title_ref","status":"blocked","task_title":"#10|qa-sdet|verify 11","spec":"Read these files\n\n# verify"},
 {"id":"t_other_title","status":"blocked","task_title":"#12|qa-sdet","spec":"no ref here"},
 {"id":"t_no_ref","status":"blocked","task_title":"New messages","spec":"no ref here"}
]}}
EOF
cat >"$tmp/bin/orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_LOG"
case "$2" in
  task-list) [ "${ORCA_FAIL:-}" != 1 ] || exit 1; cat "$TASKS" ;;
esac
EOF
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$2" in
  repos/acme/dots/issues/10|repos/acme/dots/issues/11) echo closed ;;
  repos/acme/dots/issues/12) echo open ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/orca" "$tmp/bin/gh"
export ORCA_LOG="$tmp/orca.log" GH_LOG="$tmp/gh.log" TASKS="$tmp/tasks.json" ORCA_CLI_COMMAND="$tmp/bin/orca"
run() {
  : >"$ORCA_LOG"; : >"$GH_LOG"
  out=$(PATH="$tmp/bin:$PATH" bash "$script" --run run_x --repo acme/dots "$@" 2>"$tmp/err")
  ec=$?
}
run
[ "$ec" = 0 ] && ok || bad "dry run exits 0 ($ec)"
grep -q '^t_blocked_closed blocked -> completed' <<<"$out" && ok || bad "a blocked task with a closed issue is listed ($out)"
grep -q '^t_failed_closed failed -> completed' <<<"$out" && ok || bad "a bare Refs counts as the host repo ($out)"
grep -q '^t_title_ref blocked -> completed' <<<"$out" && ok || bad "with no Refs line the #N| title counts ($out)"
for id in t_blocked_open t_other_title t_done t_other_repo t_missing t_no_ref; do
  grep -q "$id" <<<"$out" && bad "$id must not be swept ($out)" || ok
done
grep -q 'task-update' "$ORCA_LOG" && bad "dry run must not update" || ok
grep -q '3 stale task' <<<"$out" && ok || bad "summary counts 3 ($out)"
grep -q '1 task(s) kept' "$tmp/err" && ok || bad "an unreadable issue is counted on stderr ($(cat "$tmp/err"))"
run --apply
grep -Fxq 'orchestration task-update --run run_x --id t_blocked_closed --status completed --result swept: acme/dots#10 is closed' "$ORCA_LOG" && ok || bad "apply updates the blocked task ($(cat "$ORCA_LOG"))"
grep -q -- '--id t_failed_closed' "$ORCA_LOG" && ok || bad "apply updates the failed task"
[ "$(grep -c task-update "$ORCA_LOG")" = 3 ] && ok || bad "apply updates only the three stale tasks"
ORCA_FAIL=1 run --apply
[ "$ec" = 0 ] && grep -q 'could not list tasks' "$tmp/err" && ok || bad "a failed task-list exits 0 with a warning"
set +e
bash "$script" >/dev/null 2>&1
[ "$?" = 2 ] && ok || bad "a missing --run exits 2"
set -e
echo "task-sweep: $pass passed, $fail failed"
[ "$fail" = 0 ]
