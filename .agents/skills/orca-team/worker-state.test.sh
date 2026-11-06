#!/usr/bin/env bash
# One test per past incident for worker_state.can_remove and can_close.
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
t() { # <name> <python expression that must be true>
  if python3 -c "import sys; sys.path.insert(0, '$here'); import worker_state as ws; sys.exit(0 if ($2) else 1)"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi
}
REL='{"dispatchId":"d1","dispatchStatus":"released","worktreeId":"repo::/w/a"}'
LIVE='{"dispatchId":"d2","dispatchStatus":"running","worktreeId":"repo::/w/a"}'
t "released owner frees the worktree and names the dispatch" "ws.can_remove([$REL], '/w/a') == (True, '', ['d1'])"
t "a live dispatch of another Run on the same worktree keeps it (after merge cleanup incident, #600)" "ws.can_remove([$REL, $LIVE], '/w/a')[0] is False"
t "a worktree no dispatch owns stays" "ws.can_remove([$REL], '/w/b') == (False, 'no Orca dispatch owns it', [])"
t "flat row released by terminalState frees it" "ws.can_remove([{'dispatchId':'d3','state':'succeeded','terminalState':'released','workspace':'repo::/w/c'}], '/w/c')[0] is True"
t "flat row that succeeded but is not released stays" "ws.can_remove([{'dispatchId':'d4','state':'succeeded','workspace':'repo::/w/c'}], '/w/c')[0] is False"
t "symlinked path matches through the real function" "ws.can_remove([$REL], '/real/a', lambda p: p.replace('/w/','/real/'))[0] is True"
t "ended dispatch may close its panes (pane-close incident)" "ws.can_close({'state':'succeeded'}) is True"
t "running dispatch may not close its panes" "ws.can_close({'state':'running'}) is False"
t "unreadable show proves nothing and does not close" "ws.can_close({}) is False"
echo "worker_state tests: $pass passed, $fail failed"; [ "$fail" = 0 ]
