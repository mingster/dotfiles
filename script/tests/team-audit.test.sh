#!/usr/bin/env bash
# Tests for team-audit.sh against a fake dotfiles tree and a fake project.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
D="$tmp/dotfiles" P="$tmp/proj"

setup() { # a clean dotfiles tree and a project synced from it
  rm -rf "$D" "$P"
  mkdir -p "$D/script" "$D/templates/agent-team/.claude/agents" "$D/templates/agent-team/.agents/skills/elon" \
           "$D/.agents/skills/orca-team" "$P/.claude/agents" "$P/docs/agents"
  # Stand-in for agent-team.sh: records its arguments, and fails ("drift") when a team skill was hand edited.
  cat > "$D/script/agent-team.sh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "${AGENT_TEAM_CALLS:-/dev/null}"
[ "$1" = "check" ] || exit 2
if grep -rqs 'hand edit' "$2/.agents/skills"; then echo "drift: $2/.agents/skills"; exit 1; fi
EOS
  printf -- '---\nname: elon\ndescription: Elon protocol.\n---\n\nThe Tech Lead pushes and merges.\n' > "$D/templates/agent-team/.agents/skills/elon/SKILL.md"
  printf -- '---\nname: orca-team\ndescription: Orca workers.\n---\n' > "$D/.agents/skills/orca-team/SKILL.md"
  for h in worker-panes.sh worker-pane.sh worker-pane-close.sh worker-pane-retry.sh worker-watch.sh role-colors.tsv; do
    touch "$D/.agents/skills/orca-team/$h"
  done
  printf '{"version": 3, "skills": {"orca-cli": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
  printf -- '---\nname: tech-lead\n---\nYou integrate branches and report to Elon.\n' > "$P/.claude/agents/tech-lead.md"
  printf 'The Tech Lead merges every PR.\n' > "$P/docs/agents/team.md"
  mkdir -p "$P/.agents/skills/elon"; cp "$D/templates/agent-team/.agents/skills/elon/SKILL.md" "$P/.agents/skills/elon/"
  mkdir -p "$D/.agents/skills/tdd"; printf -- '---\nname: tdd\ndescription: Test first.\n---\n' > "$D/.agents/skills/tdd/SKILL.md"
  GH_FAIL="" GH_READY="[]"; : > "$GH_CALLS"
}

# Fake gh on PATH. Every call is appended to $GH_CALLS as one line. issue list --label ready-for-agent prints $GH_READY;
# api graphql and the month's issue list print the fixtures; GH_FAIL makes every call fail.
fx="$here/tests/fixtures"
export GH_CALLS="$tmp/gh-calls" GH_FX="$fx"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
echo "$*" | tr '\n' ' ' >> "$GH_CALLS"; echo >> "$GH_CALLS"
[ -n "$GH_FAIL" ] && exit 1
case "$1 $2" in
  "api graphql") cat "$GH_FX/team-audit-graphql.json" ;;
  "issue list") case " $* " in *" --label ready-for-agent "*) printf '%s' "$GH_READY" ;; *) cat "$GH_FX/team-audit-issues.json" ;; esac ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

withremote() { ( cd "$P" && git init -q && git remote add origin https://github.com/acme/project-alpha.git ); }
commit() { # <repo> <message>: commit everything with a fixed identity
  ( cd "$1" && git add -A && git -c user.name=t -c user.email=t@t commit -qm "$2" )
}

pass=0; fail=0
check() { # name expected_exit output_regex
  out=$(DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1); code=$?
  if [ "$code" = "$2" ] && echo "$out" | grep -qE "$3"; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1 (exit $code)"; echo "$out"; fi
}

setup
check "clean tree passes" 0 'team-audit: clean'

setup; echo 'When a review passes, the Tech Lead merges it.' >> "$P/docs/agents/team.md"
check "lead merging is allowed" 0 'team-audit: clean'

setup; echo 'sales pushes its branch.' >> "$P/docs/agents/team.md"
check "sales pushing is allowed" 0 'team-audit: clean'

setup; echo 'Then release-manager opens the PR.' >> "$P/.claude/agents/tech-lead.md"
check "a role opening a PR is allowed" 0 'team-audit: clean'

setup; echo 'fullstack-dev merges the PR.' >> "$P/docs/agents/team.md"
check "implementation worker merging a PR is banned" 1 'FINDING wording: .*team.md'

setup; echo 'release-manager merges the PR.' >> "$P/docs/agents/team.md"
check "release-manager merging a PR is banned" 1 'FINDING wording: .*team.md'

setup; echo 'Workers open a PR and merge it when checks pass.' >> "$P/docs/agents/team.md"
check "open a PR and merge it is banned" 1 'FINDING wording: .*team.md'

setup; echo 'fullstack-dev merges `main` into the branch.' >> "$P/docs/agents/team.md"
check "merging main into a branch is allowed" 0 'team-audit: clean'

setup; echo 'Keep task_plan.md current.' >> "$P/docs/agents/team.md"
check "task_plan ledger is banned" 1 'FINDING wording: .*task_plan'

setup; echo 'Run orca claude-teams for panes.' >> "$P/docs/agents/team.md"
check "old pane layout is banned" 1 'FINDING wording: .*claude-teams'

setup; echo 'Light tier: gpt-6-luna low.' >> "$P/.claude/model-routing.md"
check "retired luna model is banned" 1 'FINDING wording: .*model-routing.md'

setup; echo 'Wait with `check --wait --types worker_done,escalation --timeout-ms 900000`.' >> "$P/docs/agents/team.md"
check "a wait filter without status is banned" 1 'FINDING wording: .*team.md'

setup; echo 'Wait with `check --wait --types worker_done,escalation,status --timeout-ms 900000`.' >> "$P/docs/agents/team.md"
check "a wait filter with status is allowed" 0 'team-audit: clean'

setup; echo 'The lead merges it. <!-- team-audit: allow -->' >> "$P/docs/agents/team.md"
check "allow comment opts a line out" 0 'team-audit: clean'

setup; echo 'hand edit' >> "$P/.agents/skills/elon/SKILL.md"
check "hand edited team skill fails the sync check" 1 'FINDING sync: '

setup; export AGENT_TEAM_CALLS="$tmp/calls"; : > "$AGENT_TEAM_CALLS"
check "clean tree runs agent-team.sh check" 0 'team-audit: clean'
if grep -qxF "check $P" "$AGENT_TEAM_CALLS"; then pass=$((pass+1)); echo "ok   sync check calls agent-team.sh check <project>"
else fail=$((fail+1)); echo "FAIL sync check calls agent-team.sh check <project>"; fi
unset AGENT_TEAM_CALLS

# a project root that resolves to DOTFILES (here via symlink) skips the sync check only
setup; ln -s "$D" "$tmp/dotfiles-link"; export AGENT_TEAM_CALLS="$tmp/calls"; : > "$AGENT_TEAM_CALLS"
out=$(DOTFILES="$D" "$here/team-audit.sh" "$tmp/dotfiles-link" "$P" 2>&1); rc=$?
if [ "$rc" = 0 ] && echo "$out" | grep -q 'team-audit: clean'; then pass=$((pass+1)); echo "ok   DOTFILES project root exits clean"
else fail=$((fail+1)); echo "FAIL DOTFILES project root exits clean"; echo "$out"; fi
if grep -qxF "check $P" "$AGENT_TEAM_CALLS" && ! grep -qxF "check $tmp/dotfiles-link" "$AGENT_TEAM_CALLS" && ! grep -qxF "check $D" "$AGENT_TEAM_CALLS"; then pass=$((pass+1)); echo "ok   sync check skips DOTFILES, still checks other projects"
else fail=$((fail+1)); echo "FAIL sync check skips DOTFILES, still checks other projects"; cat "$AGENT_TEAM_CALLS"; fi
unset AGENT_TEAM_CALLS

# TEAM_AUDIT_RUN_METRICS=1 runs script/team-audit-metrics.ts --repo <owner/name> (fake bun, no network)
cat > "$tmp/bin/bun" <<'EOS'
#!/usr/bin/env bash
echo "bun-called $*"
EOS
chmod +x "$tmp/bin/bun"
setup; withremote
mout=$(TEAM_AUDIT_RUN_METRICS=1 DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1)
if echo "$mout" | grep -qE 'bun-called .*/script/team-audit-metrics\.ts --repo acme/project-alpha$'; then pass=$((pass+1)); echo "ok   metrics run with --repo from the origin remote"
else fail=$((fail+1)); echo "FAIL metrics run with --repo from the origin remote"; echo "$mout"; fi
setup; withremote
mout=$(DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1)
if echo "$mout" | grep -q 'bun-called'; then fail=$((fail+1)); echo "FAIL metrics are off by default"
else pass=$((pass+1)); echo "ok   metrics are off by default"; fi
rm -f "$tmp/bin/bun"

setup; yes word | head -900 | tr '\n' ' ' >> "$P/.claude/agents/tech-lead.md"
check "role file over budget" 1 'FINDING budget: .*tech-lead.md: 9[0-9][0-9] words'

setup; mkdir -p "$D/.agents/skills/bare"; printf -- '---\nname: bare\n---\n' > "$D/.agents/skills/bare/SKILL.md"
check "skill without description" 1 'FINDING skills: .*bare/SKILL.md: no description'

setup; printf '{"version": 3, "skills": {"orchestration": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
check "official orchestration may be tracked" 0 'team-audit: clean'

setup; printf '{"version": 3, "skills": {"orca-team": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
check "lock tracking our orca-team" 1 'FINDING skills: .*tracks orca-team'

setup; rm "$D/.agents/skills/orca-team/worker-panes.sh"
check "missing orca-team helper" 1 'FINDING skills: missing .*worker-panes.sh'

setup; rm "$D/.agents/skills/orca-team/worker-pane-retry.sh"
check "missing pane retry helper" 1 'FINDING skills: missing .*worker-pane-retry.sh'

setup; printf -- '---\nname: dev\nskills: [tdd, orchestration]\n---\nbody\n' > "$D/templates/agent-team/.claude/agents/dev.md"
check "role skills all present" 0 'team-audit: clean'

setup; printf -- '---\nname: dev\nskills: [tdd, nosuch]\n---\nbody\n' > "$P/.claude/agents/dev.md"
check "role names a skill that does not exist" 1 'FINDING skills: .*dev.md: skills: names nosuch'

setup; mkdir -p "$P/.agents/skills/local"; printf -- '---\nname: local\ndescription: x\n---\n' > "$P/.agents/skills/local/SKILL.md"
printf -- '---\nname: dev\nskills: [local]\n---\nbody\n' > "$P/.claude/agents/dev.md"
check "role may name a project skill" 0 'team-audit: clean'

# labels: one gh issue list per project with an origin
setup; withremote; GH_READY='[{"number":5,"labels":[{"name":"ready-for-agent"},{"name":"bug"}]}]'; export GH_READY
check "ready issue without a conflicting label passes" 0 'team-audit: clean'
if [ "$(grep -c '^issue list' "$GH_CALLS")" = 1 ] && ! grep -qv '^issue list' "$GH_CALLS"; then pass=$((pass+1)); echo "ok   labels check makes one gh call and no upstream polling"
else fail=$((fail+1)); echo "FAIL labels check gh calls"; cat "$GH_CALLS"; fi

setup; withremote; GH_READY='[{"number":6,"labels":[{"name":"ready-for-agent"},{"name":"needs-info"}]}]'; export GH_READY
check "ready-for-agent with needs-info is a label conflict" 1 '^FINDING labels: acme/project-alpha#6 has ready-for-agent and needs-info$'

setup; withremote; GH_FAIL=1; export GH_FAIL
check "gh failure on labels is a warning, not a finding" 0 'WARN labels'
unset GH_FAIL

# Acceptance: no drift exits 0; a role to skill mismatch plus a label conflict exits 1 naming both.
setup; withremote
check "fixture with no drift exits 0" 0 'team-audit: clean'
setup; withremote; printf -- '---\nname: dev\nskills: [nosuch]\n---\nbody\n' > "$P/.claude/agents/dev.md"
GH_READY='[{"number":7,"labels":[{"name":"ready-for-agent"},{"name":"blocked"}]}]'; export GH_READY
out=$(DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1); code=$?
if [ "$code" = 1 ] && echo "$out" | grep -q 'FINDING skills: .*names nosuch' && echo "$out" | grep -q 'FINDING labels: acme/project-alpha#7 has ready-for-agent and blocked' \
   && echo "$out" | grep -q 'team-audit: 2 finding(s)'; then pass=$((pass+1)); echo "ok   mismatch and label conflict exit 1 naming both"
else fail=$((fail+1)); echo "FAIL mismatch and label conflict (exit $code)"; echo "$out"; fi
GH_READY="[]"

# receipt: role commits need Owner-approved:, counted after the baseline sha
setup; ( cd "$D" && git init -q ); commit "$D" base
printf -- '---\nname: dev\n---\nbody\n' > "$D/templates/agent-team/.claude/agents/dev.md"; commit "$D" "edit dev role"
check "role commit without a receipt is a finding" 1 'FINDING receipt: .*touches templates/agent-team/.claude/agents without an Owner-approved: trailer \(edit dev role\)'
base=$(git -C "$D" rev-parse HEAD)
out=$(ROLE_RECEIPT_BASE="0000000 $base" DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1); code=$?
if [ "$code" = 0 ]; then pass=$((pass+1)); echo "ok   commits up to the baseline sha are not read"
else fail=$((fail+1)); echo "FAIL baseline sha (exit $code)"; echo "$out"; fi
echo more >> "$D/templates/agent-team/.claude/agents/dev.md"
( cd "$D" && git add -A && git -c user.name=t -c user.email=t@t commit -qm "approved edit" -m "Owner-approved: yes" )
echo again >> "$D/templates/agent-team/.claude/agents/dev.md"; commit "$D" "unapproved edit"
out=$(ROLE_RECEIPT_BASE="$base" DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1); code=$?
if [ "$code" = 1 ] && echo "$out" | grep -q '(unapproved edit)$' && [ "$(echo "$out" | grep -c '^FINDING receipt')" = 1 ]; then
  pass=$((pass+1)); echo "ok   only unapproved commits after the baseline are findings"
else fail=$((fail+1)); echo "FAIL receipt after baseline (exit $code)"; echo "$out"; fi

# --report: checks plus metrics (fake gh counts the calls), real bun runs team-audit-metrics.ts
if ! command -v bun >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL --report tests need bun on PATH"
else
  setup; withremote; for r in "$D" "$P"; do ( cd "$r" && { [ -d .git ] || git init -q; } && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base ); done
  printf 'date\tfinding\tevidence\tcount\tfix ticket\tstatus\n2026-11-08\tworker skipped the receipt\tPR #9, PR #12\t2\t-\topen\n' > "$tmp/obs.tsv"
  rep=$(TEAM_AUDIT_NOW=2026-11-09T12:00:00Z TEAM_AUDIT_LOG="$tmp/obs.tsv" TEAM_AUDIT_DISPATCHES="$fx/team-audit-dispatches.tsv" \
    DOTFILES="$D" "$here/team-audit.sh" --report "$P" 2>&1); code=$?
  rcheck() { # name regex
    if echo "$rep" | grep -qE -- "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "$rep"; fi
  }
  if [ "$code" = 0 ]; then pass=$((pass+1)); echo "ok   --report on a clean fixture exits 0"; else fail=$((fail+1)); echo "FAIL --report exit $code"; echo "$rep"; fi
  rcheck "--report has the problems section" '^## Problems with evidence$'
  rcheck "--report has the proposals section" '^## Proposals with a recommended option$'
  rcheck "--report has the stage times section" '^## Stage times$'
  rcheck "--report lists TSV rows with evidence" '^- worker skipped the receipt \(logged 2026-11-08, count 2, evidence PR #9, PR #12'
  rcheck "--report recommends a fix ticket at count 2" 'worker skipped the receipt: Recommended: A, open a fix ticket'
  rcheck "--report prints sample and verified counts" '^Samples: 3, fully verified: 2$'
  rcheck "--report queue row" '^\| queue \| 20 \| 30 \| 30 \| 2 \| 2 \|$'
  rcheck "--report build runs from dispatch to first Checks" '^\| build \| 60 \| 90 \| 90 \| 2 \| 2 \|$'
  rcheck "--report merge row" '^\| merge \| 60 \| 120 \| 120 \| 3 \| 2 \|$'
  rcheck "--report delivery metrics" 'Delivery: median_ticket_start_to_merge_minutes=150, first_pass_checks_fail_rate=0.33, first_pass_verdict_rate=unknown'
  rcheck "--report prints ROLE_RECEIPT_BASE" '^ROLE_RECEIPT_BASE="[0-9a-f]+( [0-9a-f]+)*"$'
  n=$(wc -l < "$GH_CALLS" | tr -d ' ')
  if [ "$n" -le 3 ] && grep -q '^api graphql' "$GH_CALLS" && [ "$(grep -c '^issue list' "$GH_CALLS")" = 2 ]; then
    pass=$((pass+1)); echo "ok   --report makes $n gh calls (at most 3)"
  else fail=$((fail+1)); echo "FAIL --report made $n gh calls"; cat "$GH_CALLS"; fi

  setup; withremote; printf -- '---\nname: dev\nskills: [nosuch]\n---\nbody\n' > "$P/.claude/agents/dev.md"
  rep=$(TEAM_AUDIT_NOW=2026-11-09T12:00:00Z TEAM_AUDIT_LOG="$tmp/none.tsv" DOTFILES="$D" "$here/team-audit.sh" --report "$P" 2>&1); code=$?
  if [ "$code" = 1 ]; then pass=$((pass+1)); echo "ok   --report with a finding exits 1"; else fail=$((fail+1)); echo "FAIL --report finding exit $code"; fi
  rcheck "--report lists the FINDING as a problem" '^- skills: .*names nosuch'
  rcheck "--report gives the finding a recommended option" '^  Recommended: A, fix the skill or role file'
  rcheck "--report without a dispatch log has no verified samples" '^Samples: 3, fully verified: 0$'
  metrics_test=$(cd "$here/tests" && pwd)/team-audit-metrics.test.ts
  if bun test "$metrics_test"; then
    pass=$((pass+1)); echo "ok   team-audit-metrics unit tests"
  else
    fail=$((fail+1)); echo "FAIL team-audit-metrics unit tests"
  fi
fi

setup
out=$(DOTFILES="$D" "$here/team-audit.sh" --bogus 2>&1); code=$?
if [ "$code" = 2 ]; then pass=$((pass+1)); echo "ok   unknown flag is a usage error"; else fail=$((fail+1)); echo "FAIL unknown flag (exit $code)"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
