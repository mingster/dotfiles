#!/usr/bin/env bash
# Start the cross family reviewer for a coding worker_done.
# on-worker-done.sh --repo owner/name --pr N --head SHA --author-family claude|cursor|gemini|antigravity
#                   --worktree PATH --run RUN [--author-dispatch ID] [--owner LEAD_HANDLE] [--resolution] [--dry-run]
# Prints the worker-start command (runs it unless --dry-run). Writes the reviewer brief to a temp file.
# Writes the reviewer's owner record ($WORKER_DONE_OWNER_DIR/<its dispatch id>: the lead handle from --owner, then
# kind=reviewer, repo=, pr=) so worker-done-relay.sh sweep can release the seat on proof. No dispatch id in the output: no record.
# Before any gate or reviewer: if <worktree>/.agents/pre-qa-checks.conf exists, its commands run at the exact head (one per
# line, each limited to ON_WORKER_DONE_CHECK_TIMEOUT seconds, default 120). A failure, timeout or moved head starts no reviewer.
# A repeat call for the same repo, PR, head and kind (review or --resolution) starts no second reviewer (marker in ON_WORKER_DONE_REVIEWER_DIR).
# Checks also start only if the head is unchanged and the worktree clean after the cheap checks.
# Then, still before any gate or reviewer, head-checks.sh --repo <worktree> --pr N starts detached (output in a log, once per repo,
# PR and head via a marker; none if the worktree or PR head moved or a Checks comment for the head exists). The reviewer never waits on it.
# Env: ON_WORKER_DONE_HEAD_CHECKS, ON_WORKER_DONE_CHECKS_DIR, ON_WORKER_DONE_CHECKS_LOG_DIR override head-checks.sh, markers, logs (tests).
#      ON_WORKER_DONE_USAGE_GATE overrides usage-gate.py (tests).
#      ON_WORKER_DONE_FLEET_CONFIG selects the fleet-config.json with host caps and optional load ceilings.
#      ON_WORKER_DONE_ADMISSION_POLICY optional operator-owned narrowing JSON. qa-admission.py validates workspace.
set -u
usage() { echo "usage: ${0##*/} --repo owner/name --pr N --head SHA [--author-family claude|cursor|gemini|antigravity] [--author-provider PROVIDER] [--author-model MODEL] --worktree PATH --run RUN [--author-dispatch ID] [--owner LEAD_HANDLE] [--resolution] [--dry-run]" >&2; exit 2; }
owner="" repo="" pr="" head="" fam="" author_provider="" author_model="" wt="" run="" author_dispatch=unknown dry=0 resolution=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --resolution) resolution=1; shift ;;
    --repo|--pr|--head|--author-family|--author-provider|--author-model|--worktree|--run|--author-dispatch|--owner)
      [ $# -ge 2 ] || usage
      case "$1" in
        --repo) repo=$2 ;; --pr) pr=$2 ;; --head) head=$2 ;; --author-family) fam=$2 ;;
        --author-provider) author_provider=$2 ;; --author-model) author_model=$2 ;;
        --worktree) wt=$2 ;; --run) run=$2 ;; --author-dispatch) author_dispatch=$2 ;; --owner) owner=$2 ;;
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
  case "$fam" in claude|cursor|gemini|antigravity) ;; *) usage ;; esac
  [ -n "$author_provider" ] || author_provider="$fam"
fi

# Cheap checks: the project's .agents/pre-qa-checks.conf (one command per line, # comments and blank lines skipped)
# runs from the worktree at the exact head before any reviewer starts. No file: nothing runs.
cheap_conf="$wt/.agents/pre-qa-checks.conf"
if [ -f "$cheap_conf" ]; then
  now=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || now=""
  if [ "$now" != "$head" ]; then
    echo "QA start refused head=$head: head moved, the worktree is at ${now:-an unreadable head}" >&2
    exit 1
  fi
  python3 - "$cheap_conf" "$wt" "${ON_WORKER_DONE_CHECK_TIMEOUT:-120}" "$head" <<'PY' || exit 1
import os, signal, subprocess, sys

conf, wt, limit, head = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
for line in open(conf):
    cmd = line.strip()
    if not cmd or cmd.startswith("#"):
        continue
    proc = subprocess.Popen(["bash", "-c", cmd], cwd=wt, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace", start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=limit)
        why = None if proc.returncode == 0 else f"exit {proc.returncode}"
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, _ = proc.communicate()
        why = f"timed out after {limit:g}s"
    if why:
        tail = "\n".join((out or "").splitlines()[-20:])
        sys.exit(f"QA start refused head={head}: cheap check failed ({why}): {cmd}\n{tail}")
PY
fi

# Checks start: the cheap checks have passed (or none are configured), so head-checks.sh --pr N starts detached beside QA.
# One start per repo, PR and head: mkdir takes the marker atomically; a run that fails clears it so a retry can start.
# Nothing starts when the worktree or the PR head moved, or a Checks comment for this head already exists.
_here=$(cd "$(dirname "$0")" && pwd)
checks_note() { printf 'Checks not started head=%s: %s\n' "$head" "$1"; }
start_checks() {
  local now info state hc slug dir marker log
  now=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || now=""
  [ "$now" = "$head" ] || { checks_note "the worktree is at ${now:-an unreadable head}"; return 0; }
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || { checks_note "the worktree is dirty"; return 0; }
  info=$(gh pr view "$pr" --repo "$repo" --json headRefOid,comments 2>/dev/null) || { checks_note "cannot read the PR"; return 0; }
  state=$(printf '%s' "$info" | python3 -c '
import json, re, sys
head = sys.argv[1]
try:
    pr = json.load(sys.stdin)
    if pr["headRefOid"] != head:
        print("moved")
    elif any(re.match(r"^Checks: (?:PASS|FAIL) head=" + head + r"(?:\s|$)", c.get("body", "")) for c in pr["comments"]):
        print("posted")
    else:
        print("go")
except (ValueError, KeyError, TypeError, AttributeError):
    print("unreadable")
' "$head")
  case "$state" in
    moved) checks_note "the PR head moved"; return 0 ;;
    posted) checks_note "a Checks comment already exists for this head"; return 0 ;;
    go) ;;
    *) checks_note "cannot read the PR"; return 0 ;;
  esac
  hc=${ON_WORKER_DONE_HEAD_CHECKS:-$_here/head-checks.sh}
  slug=$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')
  dir=${ON_WORKER_DONE_CHECKS_DIR:-$HOME/.claude/state/checks-started}
  marker="$dir/$slug-$pr-$head"
  log="${ON_WORKER_DONE_CHECKS_LOG_DIR:-${TMPDIR:-/tmp}}/on-worker-done-checks-$slug-$pr-${head:0:12}.log"
  if [ "$dry" = 1 ]; then
    if [ -e "$marker" ]; then checks_note "already started"; else printf 'Checks would start: bash %q --repo %q --pr %s (log %s)\n' "$hc" "$wt" "$pr" "$log"; fi
    return 0
  fi
  mkdir -p "$dir" "$(dirname "$log")" 2>/dev/null || { checks_note "cannot write the start marker or log"; return 0; }
  mkdir "$marker" 2>/dev/null || { checks_note "already started"; return 0; }
  if python3 -c '
import subprocess, sys

marker, log, hc, wt, pr = sys.argv[1:]
wrap = "m=$1; shift; \"$@\"; rc=$?; [ \"$rc\" = 0 ] || rmdir \"$m\"; exit \"$rc\""
try:
    with open(log, "ab") as out:
        subprocess.Popen(["bash", "-c", wrap, "_", marker, "bash", hc, "--repo", wt, "--pr", pr],
                         stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
except OSError as err:
    sys.exit(str(err))
' "$marker" "$log" "$hc" "$wt" "$pr"; then
    printf 'Checks started head=%s pr=%s log=%s\n' "$head" "$pr" "$log"
  else
    rmdir "$marker" 2>/dev/null
    checks_note "the start failed"
  fi
}
start_checks

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
    if p == "cursor":
        return "composer"
    if p in ("antigravity", "gemini"):
        return "gemini"
    return "unknown"

fam = get_family(provider, model)
avoid_fam = fam if fam in ("claude", "gpt", "gemini", "composer") else "none"
avoid_prov = provider if provider == "claude" else "none"
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
    if p == "cursor":
        return "composer"
    if p in ("antigravity", "gemini"):
        return "gemini"
    return "unknown"

ver_fam = get_family(ver_prov, ver_model)
ok = "1"
if ver_fam == "unknown" or ver_fam == author_fam:
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
  fleet_config="$HOME/.claude/state/fleet-config.json"
fi
policy=${ON_WORKER_DONE_ADMISSION_POLICY:-}
if [ -n "$policy" ] && [ ! -f "$policy" ]; then
  echo "QA start refused head=$head: admission policy missing or unreadable" >&2
  exit 1
fi
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
# Capture the parser exit explicitly: process substitution would hide failure.
if ! admission_fields=$(python3 - "$admission_out" <<'PYJSON'
import json, re, sys
try:
    with open(sys.argv[1]) as stream:
        result = json.load(stream)
    if not isinstance(result, dict):
        raise ValueError("object required")
    environment = result["environment_id"]
    selector = result["worktree_selector"]
    host = result["host"]
    if not isinstance(environment, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", environment) or environment == "LOCAL":
        raise ValueError("saved ID required")
    if not isinstance(selector, str) or not re.fullmatch(r"identity:wt2:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+", selector):
        raise ValueError("native identity required")
    if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", host):
        raise ValueError("host required")
except (ValueError, KeyError, TypeError):
    sys.exit("invalid validated admission result")
print(environment, selector)
PYJSON
); then
  echo "QA start refused head=$head: invalid validated admission result" >&2
  rm -f "$admission_err" "$admission_out"
  exit 1
fi
read -r environment_id worktree_selector <<< "$admission_fields"
rm -f "$admission_err" "$admission_out"
if [ "$environment_id" != local ]; then
  host_flags=(--on "$environment_id")
fi

# All coding reviewer providers enter here. Read the latest receipt for this
# exact head before starting a worker or producing a reviewer brief.
comments=$(gh pr view "$pr" --repo "$repo" --json comments) || {
  echo "QA start refused head=$head: cannot read head-checks receipts" >&2
  exit 1
}
# Prints "pending" when no receipt exists at this exact head; QA starts anyway.
# A Checks: FAIL, a bad receipt or an unreadable comment list still refuses.
checks_state=$(printf '%s' "$comments" | python3 -c '
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
if not exact:
    print("pending")
    sys.exit(0)
body = exact[-1]
if body.startswith("Checks: FAIL "):
    print("needs-author")
    refuse("Checks: FAIL (needs-author)")
if not body.startswith("Checks: PASS "):
    refuse("no Checks: PASS receipt for this head")
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
' "$head") || { [ -n "$checks_state" ] && printf '%s\n' "$checks_state"; exit 1; }

brief=$(mktemp "${TMPDIR:-/tmp}/reviewer-brief.XXXXXX")
gate_footer='Look for the Checks receipt for exactly this head on this PR (a comment body starting with Checks: PASS head='"$head"' or Checks: FAIL head='"$head"'). If it is Checks: PASS, cite it for automated check outcomes. If it is Checks: FAIL, stop the review and post Verdict: FAIL. Never rerun bun test, tsc, lint, or the regression suite.'
if [ "$checks_state" = pending ]; then
  gate_footer="Checks are pending: no Checks receipt exists for head $head yet. That is not a failure. Review the code anyway and say in your verdict that Checks were pending. $gate_footer"
fi
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
Use the code-review skill (Dual-Axis): check the diff against the PR's spec and the repo's standards. Prove load-bearing behaviour live; do not rerun bun test, tsc, lint, or regression.
Lint only the PR's changed files, never a whole repo lint with autofix (it rewrites files in the author's worktree).
$gate_footer
Post exactly one PR comment whose first line is:
Verdict: PASS|PASS+NOTES|FAIL head=$head verifier=<your dispatch id> author=$author_dispatch
Use one of PASS, PASS+NOTES or FAIL. Put findings on the lines after it. Do not edit the PR.
EOF
fi

cmd="$orca orchestration worker-start --run $run --spec \"\$(cat $brief)\" --worktree $worktree_selector --task-title \"reviewer - PR $pr\" ${host_flags[*]+"${host_flags[@]}"} $flags --json"
[ "$dry" = 1 ] && { echo "$cmd"; exit 0; }
# One reviewer per repo, PR, head and kind: a repeat worker_done for the same head starts none. A failed start clears the marker.
rdir=${ON_WORKER_DONE_REVIEWER_DIR:-$HOME/.claude/state/reviewer-started}
rmarker="$rdir/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')-$pr-$head-$([ "$resolution" = 1 ] && echo resolution || echo review)"
mkdir -p "$rdir" || { echo "on-worker-done: cannot write the reviewer start marker" >&2; exit 1; }
if ! mkdir "$rmarker" 2>/dev/null; then
  printf 'Reviewer not started head=%s: already started\n' "$head"
  exit 0
fi
echo "$cmd"
# shellcheck disable=SC2086
started=$($orca orchestration worker-start --run "$run" --spec "$(cat $brief)" --worktree "$worktree_selector" --task-title "reviewer - PR $pr" ${host_flags[@]+"${host_flags[@]}"} $flags --json)
rc=$?
printf '%s\n' "$started"
[ "$rc" = 0 ] || { rmdir "$rmarker" 2>/dev/null; exit "$rc"; }
reviewer_dispatch=$(printf '%s' "$started" | python3 -c '
import json, re, sys
def find(node):
    if isinstance(node, dict):
        if isinstance(node.get("dispatchId"), str):
            return node["dispatchId"]
        node = list(node.values())
    if isinstance(node, list):
        for value in node:
            found = find(value)
            if found:
                return found
try:
    found = find(json.load(sys.stdin))
except ValueError:
    found = None
print(found if found and re.fullmatch(r"[A-Za-z0-9_-]+", found) else "")
')
if [ -n "$reviewer_dispatch" ]; then
  owners=${WORKER_DONE_OWNER_DIR:-$HOME/.claude/state/dispatch-owners}
  { mkdir -p "$owners" && printf '%s\nkind=reviewer\nrepo=%s\npr=%s\n' "$owner" "$repo" "$pr" > "$owners/$reviewer_dispatch"; } \
    || echo "on-worker-done: could not write the owner record for $reviewer_dispatch" >&2
fi
exit 0
