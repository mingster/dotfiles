#!/usr/bin/env bash
# Tests for worker-pane.sh role colors using a fake orca script (no live Orca needed).
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "orchestration worker-show"*) printf '{"result":{"dispatch":{"assigneeHandle":"-","status":"completed","taskTitle":"%s"}}}' "$FAKE_TITLE" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
pane() { FAKE_TITLE="$1" "$here/worker-pane.sh" d1 ${2:+"$2"} 2>/dev/null; }

check "secops-finops gets 124" "$(pane 'secops-finops - review PR 1729' | grep -q '48;5;124m'; echo $?)"
check "lead gets 25" "$(pane 'lead - merge PRs' | grep -q '48;5;25m'; echo $?)"
check "tech-lead gets 25" "$(pane 'tech-lead - merge PRs' | grep -q '48;5;25m'; echo $?)"
check "unknown role gets 240" "$(pane 'intern - make coffee' | grep -q '48;5;240m'; echo $?)"
check "no dash in title gets 240" "$(pane 'whatever' | grep -q '48;5;240m'; echo $?)"
check "explicit color overrides role" "$(pane 'secops-finops - x' 5 | grep -q '48;5;5m'; echo $?)"
check "--role-color fullstack-dev is 28" "$([ "$("$here/worker-pane.sh" --role-color 'fullstack-dev - fix')" = 28 ]; echo $?)"
check "--role-color is case insensitive" "$([ "$("$here/worker-pane.sh" --role-color 'Elon - plan')" = 178 ]; echo $?)"

check "ended dispatch prints no hold text" "$(pane 'lead - x' | grep -q 'pane stays'; [ $? = 1 ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
