#!/usr/bin/env bash
# Start the cross family reviewer for a coding worker_done.
# on-worker-done.sh --repo owner/name --pr N --head SHA --author-family claude|cursor|codex|antigravity
#                   --worktree PATH --run RUN [--author-dispatch ID] [--resolution] [--dry-run]
# Prints the worker-start command (runs it unless --dry-run). Writes the reviewer brief to a temp file.
# Env: ON_WORKER_DONE_USAGE_GATE overrides usage-gate.py (tests).
#      ON_WORKER_DONE_FLEET_CONFIG / ON_WORKER_DONE_FLEET_WATCH override fleet-watch (tests).
#      ON_WORKER_DONE_ADMISSION_POLICY operator-owned JSON (required). qa-admission.py validates workspace.
set -u
usage() { echo "usage: ${0##*/} --repo owner/name --pr N --head SHA [--author-family claude|cursor|codex|antigravity] [--author-provider PROVIDER] [--author-model MODEL] --worktree PATH --run RUN [--author-dispatch ID] [--resolution] [--dry-run]" >&2; exit 2; }
repo="" pr="" head="" fam="" author_provider="" author_model="" wt="" run="" author_dispatch=unknown dry=0 resolution=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --resolution) resolution=1; shift ;;
    --repo|--pr|--head|--author-family|--author-provider|--author-model|--worktree|--run|--author-dispatch)
      [ $# -ge 2 ] || usage
      case "$1" in
        --repo) repo=$2 ;; --pr) pr=$2 ;; --head) head=$2 ;; --author-family) fam=$2 ;;
        --author-provider) author_provider=$2 ;; --author-model) author_model=$2 ;;
        --worktree) wt=$2 ;; --run) run=$2 ;; --author-dispatch) author_dispatch=$2 ;;
      esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$repo" ] && [ -n "$pr" ] && [ -n "$head" ] && [ -n "$wt" ] && [ -n "$run" ] || usage
[ -n "$fam" ] || [ -n "$author_provider" ] || [ -n "$author_model" ] || usage
[[ "$pr" =~ ^[0-9]+$ ]] || usage
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$author_dispatch" =~ ^[a-zA-Z0-9_-]+$ ]] || usage
if [ -n "$fam" ]; then
  case "$fam" in claude|cursor|codex|antigravity) ;; *) usage ;; esac
  [ -n "$author_provider" ] || author_provider="$fam"
fi

gate=${ON_WORKER_DONE_USAGE_GATE:-$HOME/dotfiles/script/usage-gate.py}
orca=${ORCA_CLI_COMMAND:-orca}

read -r author_provider author_family avoid_family avoid_provider < <(python3 - "$author_provider" "$author_model" <<'PY'
import sys

provider, model = sys.argv[1], sys.argv[2]
def get_family(p, m):
    if m:
        ml = m.lower()
        if ml.startswith("claude-") or "claude" in ml or ml.startswith("sonnet") or ml.startswith("opus") or ml.startswith("haiku"):
            return "claude"
        if ml.startswith("gpt-") or "gpt" in ml or ml.startswith("o1") or ml.startswith("o3"):
            return "gpt"
        if ml.startswith("composer"):
            return "composer"
        if ml.startswith("gemini-") or "gemini" in ml:
            return "gemini"
        return "unknown"
    if p == "claude":
        return "claude"
    if p in ("codex", "cursor"):
        return "gpt"
    if p == "antigravity":
        return "gemini"
    return "unknown"

fam = get_family(provider, model)
avoid_fam = fam if fam in ("claude", "gpt") else "none"
avoid_prov = provider if provider in ("claude", "cursor", "codex", "antigravity") else "none"
print(f"{provider or 'unknown'} {fam} {avoid_fam} {avoid_prov}")
PY
)

if [ "$author_family" = "unknown" ]; then
  echo "cross-family unavailable" >&2
  exit 1
fi

avoid=()
[ "$avoid_family" = "none" ] || avoid+=(--avoid-family "$avoid_family")
[ "$avoid_provider" = "none" ] || avoid+=(--avoid-provider "$avoid_provider")

flags=""
if [ -x "$gate" ] || [ -f "$gate" ]; then
  # shellcheck disable=SC2086
  flags=$("$gate" pick --role reviewer ${avoid[@]+"${avoid[@]}"} 2>/dev/null) || flags=""
fi
if [ -z "$flags" ]; then
  echo "cross-family unavailable" >&2
  exit 1
fi

read -r verifier_provider verifier_family independence_ok < <(python3 - "$author_provider" "$author_family" "$flags" <<'PY'
import sys

author_prov, author_fam, flags = sys.argv[1], sys.argv[2], sys.argv[3]
tokens = flags.split()
ver_prov, ver_model = "unknown", ""
for i in range(len(tokens) - 1):
    if tokens[i] == "--agent":
        ver_prov = tokens[i+1]
    elif tokens[i] == "--model":
        ver_model = tokens[i+1]

def get_family(p, m):
    if m:
        ml = m.lower()
        if ml.startswith("claude-") or "claude" in ml or ml.startswith("sonnet") or ml.startswith("opus") or ml.startswith("haiku"):
            return "claude"
        if ml.startswith("gpt-") or "gpt" in ml or ml.startswith("o1") or ml.startswith("o3"):
            return "gpt"
        if ml.startswith("composer"):
            return "composer"
        if ml.startswith("gemini-") or "gemini" in ml:
            return "gemini"
        return "unknown"
    if p == "claude":
        return "claude"
    if p in ("codex", "cursor"):
        return "gpt"
    if p == "antigravity":
        return "gemini"
    return "unknown"

ver_fam = get_family(ver_prov, ver_model)
ok = "1"
if ver_fam == "unknown" or ver_fam == author_fam or ver_prov == author_prov:
    ok = "0"
print(f"{ver_prov} {ver_fam} {ok}")
PY
)

if [ "$independence_ok" != "1" ]; then
  echo "cross-family unavailable" >&2
  exit 1
fi

host_flags=()
worktree_selector=""
fleet_config="${ON_WORKER_DONE_FLEET_CONFIG:-}"
if [ -z "$fleet_config" ]; then
  fleet_config="$HOME/.config/fleet-watch/config.json"
fi
policy=${ON_WORKER_DONE_ADMISSION_POLICY:-}
if [ -z "$policy" ] || [ ! -f "$policy" ]; then
  echo "QA start refused head=$head: admission policy missing or unreadable" >&2
  exit 1
fi
_here=$(cd "$(dirname "$0")" && pwd)
qa_admission=${ON_WORKER_DONE_QA_ADMISSION:-$_here/qa-admission.py}
ver_model=$(python3 - "$flags" <<'PY'
import sys
tokens = sys.argv[1].split()
print(tokens[tokens.index("--model") + 1] if "--model" in tokens else "")
PY
)
admission_err=$(mktemp "${TMPDIR:-/tmp}/on-worker-done-admission.err.XXXXXX")
admission_out=$(mktemp "${TMPDIR:-/tmp}/on-worker-done-admission.out.XXXXXX")
if ! python3 "$qa_admission" --policy "$policy" --fleet-config "$fleet_config" --repo "$repo" \
    --head "$head" --worktree-path "$wt" --verifier-provider "$verifier_provider" \
    --verifier-model "$ver_model" 2>"$admission_err" >"$admission_out"; then
  echo "QA start refused head=$head: $(tr '\n' ' ' < "$admission_err")" >&2
  rm -f "$admission_err" "$admission_out"
  exit 1
fi
read -r environment_id worktree_selector < <(python3 - "$admission_out" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
print(o["environment_id"], o["worktree_selector"])
PY
)
rm -f "$admission_err" "$admission_out"
if [ "$environment_id" != "LOCAL" ] && [ -n "$environment_id" ]; then
  host_flags=(--on "$environment_id")
fi
[ -n "$worktree_selector" ] || { echo "QA start refused head=$head: missing worktree selector" >&2; exit 1; }

# All coding reviewer providers enter here. Read the latest receipt for this
# exact head before starting a worker or producing a reviewer brief.
comments=$(gh pr view "$pr" --repo "$repo" --json comments) || {
  echo "QA start refused head=$head: cannot read head-checks receipts" >&2
  exit 1
}
printf '%s' "$comments" | python3 -c '
import json, re, sys
head = sys.argv[1]
def refuse(reason):
    sys.exit(f"QA start refused head={head}: {reason}")
try:
    comments = json.load(sys.stdin)["comments"]
except (ValueError, KeyError, TypeError):
    refuse("cannot read head-checks receipts")
receipts = [c["body"] for c in comments if re.match(r"^Checks: (?:PASS|FAIL) head=[0-9a-f]{40}(?:\s|$)", c.get("body", ""))]
exact = [body for body in receipts if re.match(r"^Checks: (?:PASS|FAIL) head=" + head + r"(?:\s|$)", body)]
if receipts and not exact:
    refuse("head-checks run exists but this head has no receipt")
if exact:
    body = exact[-1]
    if re.search(r"^Tests executed: 0$", body, re.M):
        refuse("Tests executed: 0")
    errors = re.findall(r"^Load errors: ([0-9]+)$", body, re.M)
    if any(int(n) > 0 for n in errors):
        refuse("Load errors: " + str(sum(map(int, errors))))
    tests = re.findall(r"^Tests executed: ([0-9]+)$", body, re.M)
    if len(tests) != len(errors):
        refuse("incomplete test execution metadata")
    if re.search(r"^Command: .*\bbun (?:run )?test\b|^bun test v", body, re.M) and not tests:
        refuse("test command has no execution metadata")
    if body.startswith("Checks: FAIL "):
        refuse("Checks: FAIL")
' "$head" || exit 1

brief=$(mktemp "${TMPDIR:-/tmp}/reviewer-brief.XXXXXX")
gate_footer='Run scoped tests through ~/dotfiles/script/heavy-gate.sh. Waiting on the gate means those checks were not executed yet; an observed failure still counts as a failure.
Read the PR Checks receipt for this head last; pending is not PASS and never substitutes for executed tests.'
if [ "$resolution" = 1 ]; then
  cat > "$brief" <<EOF
Review the conflict-resolution merge for PR #$pr in $repo at head $head. You did not write this merge resolution.
Author: provider=$author_provider family=$author_family
Verifier: provider=$verifier_provider family=$verifier_family
Inspect only the resolution with git show --remerge-diff. Do not run a full Dual-Axis standards review of the entire PR again.
Lint only the PR's changed files, never a whole repo lint with autofix (it rewrites files in the author's worktree).
$gate_footer
Post exactly one PR comment whose first line is:
Verdict: PASS|PASS+NOTES|FAIL head=$head verifier=<your dispatch id> author=$author_dispatch
Use one of PASS, PASS+NOTES or FAIL. Put findings on the lines after it. Do not edit the PR.
EOF
else
  cat > "$brief" <<EOF
Review PR #$pr in $repo at head $head. You did not write this code, so review it cold.
Author: provider=$author_provider family=$author_family
Verifier: provider=$verifier_provider family=$verifier_family
Use the code-review skill (Dual-Axis): check the diff against the PR's spec and the repo's standards. Run the tests.
Lint only the PR's changed files, never a whole repo lint with autofix (it rewrites files in the author's worktree).
$gate_footer
Post exactly one PR comment whose first line is:
Verdict: PASS|PASS+NOTES|FAIL head=$head verifier=<your dispatch id> author=$author_dispatch
Use one of PASS, PASS+NOTES or FAIL. Put findings on the lines after it. Do not edit the PR.
EOF
fi

cmd="$orca orchestration worker-start --run $run --spec \"\$(cat $brief)\" --worktree $worktree_selector --task-title \"reviewer - PR $pr\" ${host_flags[*]+"${host_flags[@]}"} $flags --json"
echo "$cmd"
[ "$dry" = 1 ] && exit 0
# shellcheck disable=SC2086
exec $orca orchestration worker-start --run "$run" --spec "$(cat "$brief")" --worktree "$worktree_selector" --task-title "reviewer - PR $pr" ${host_flags[@]+"${host_flags[@]}"} $flags --json
