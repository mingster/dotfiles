#!/usr/bin/env bash
# Start the cross family reviewer for a coding worker_done.
# on-worker-done.sh --repo owner/name --pr N --head SHA --author-family claude|cursor|gemini|antigravity
#                   --worktree PATH --run RUN [--author-dispatch ID] [--resolution] [--dry-run]
# Prints the worker-start command (runs it unless --dry-run). Writes the reviewer brief to a temp file.
# Env: ON_WORKER_DONE_USAGE_GATE overrides usage-gate.py (tests).
#      ON_WORKER_DONE_FLEET_CONFIG selects configured host caps and optional load ceilings.
#      ON_WORKER_DONE_ADMISSION_POLICY optional operator-owned narrowing JSON. qa-admission.py validates workspace.
set -u
usage() { echo "usage: ${0##*/} --repo owner/name --pr N --head SHA [--author-family claude|cursor|gemini|antigravity] [--author-provider PROVIDER] [--author-model MODEL] --worktree PATH --run RUN [--author-dispatch ID] [--resolution] [--dry-run]" >&2; exit 2; }
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
  case "$fam" in claude|cursor|gemini|antigravity) ;; *) usage ;; esac
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
        if "grok" in ml:
            return "grok"
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
avoid_fam = fam if fam in ("claude", "gpt", "gemini", "composer", "grok") else "none"
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
        if "grok" in ml:
            return "grok"
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
  fleet_config="$HOME/.config/fleet-watch/config.json"
fi
policy=${ON_WORKER_DONE_ADMISSION_POLICY:-}
if [ -n "$policy" ] && [ ! -f "$policy" ]; then
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
    repo_id = result.get("repo_id", "")
    if not isinstance(environment, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", environment) or environment == "LOCAL":
        raise ValueError("saved ID required")
    if not isinstance(selector, str) or not re.fullmatch(r"identity:wt2:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+", selector):
        raise ValueError("native identity required")
    if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", host):
        raise ValueError("host required")
    if not isinstance(repo_id, str) or not repo_id:
        raise ValueError("repo_id required")
except (ValueError, KeyError, TypeError):
    sys.exit("invalid validated admission result")
print(environment, selector, repo_id)
PYJSON
); then
  echo "QA start refused head=$head: invalid validated admission result" >&2
  rm -f "$admission_err" "$admission_out"
  exit 1
fi
read -r environment_id worktree_selector admission_repo_id <<< "$admission_fields"
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
blocks, cur = [], None
for line in body.splitlines():
    if line.startswith("Command: "):
        if cur is not None:
            blocks.append(cur)
        cur = [line]
    elif cur is not None:
        cur.append(line)
if cur is not None:
    blocks.append(cur)
bun_actually_ran = False
for block in blocks:
    block_text = "\n".join(block)
    if re.search(r"^Skipped:", block_text, re.M):
        continue
    if re.search(r"^bun test v", block_text, re.M):
        bun_actually_ran = True
        break
if bun_actually_ran and not tests:
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
Post the Verdict with ~/dotfiles/script/post-verdict.sh --repo $repo --pr $pr --result PASS|PASS+NOTES|FAIL --head $head --verifier <your dispatch id> --author $author_dispatch --notes "<findings>" (which posts the review status and one PR comment whose first line is):
Verdict: PASS|PASS+NOTES|FAIL head=$head verifier=<your dispatch id> author=$author_dispatch
Use one of PASS, PASS+NOTES or FAIL. Put findings on the lines after it. Do not edit the PR.
EOF
else
  cat > "$brief" <<EOF
Review PR #$pr in $repo at head $head. You did not write this code, so review it cold.
Author: provider=$author_provider family=$author_family
Verifier: provider=$verifier_provider family=$verifier_family
Use the code-review skill (Dual-Axis): check the diff against the PR's spec and the repo's standards. Prove load-bearing behaviour live and run the ticket's Playwright Proving command on a host with a database; no run means no PASS. Do not rerun bun test, tsc, lint, or regression.
Lint only the PR's changed files, never a whole repo lint with autofix (it rewrites files in the author's worktree).
$gate_footer
Post the Verdict with ~/dotfiles/script/post-verdict.sh --repo $repo --pr $pr --result PASS|PASS+NOTES|FAIL --head $head --verifier <your dispatch id> --author $author_dispatch --notes "<findings>" (which posts the review status and one PR comment whose first line is):
Verdict: PASS|PASS+NOTES|FAIL head=$head verifier=<your dispatch id> author=$author_dispatch
Use one of PASS, PASS+NOTES or FAIL. Put findings on the lines after it. Do not edit the PR.
EOF
fi

pr_branch=$(gh pr view "$pr" --repo "$repo" --json headRefName -q .headRefName 2>/dev/null) || {
  echo "QA start refused head=$head: cannot read PR head branch" >&2
  exit 1
}
if [ "$environment_id" = local ]; then
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "QA start refused head=$head: cannot resolve repository root from worktree" >&2
    exit 1
  }
  repo_root=$(dirname "$(cd -P "$common" && pwd)") || {
    echo "QA start refused head=$head: cannot resolve repository root from worktree" >&2
    exit 1
  }
  repo_root_physical=$(cd -P "$repo_root" && pwd) || {
    echo "QA start refused head=$head: cannot resolve repository root from worktree" >&2
    exit 1
  }
  repo_list_json=$("$orca" repo list --json 2>/dev/null) || {
    echo "QA start refused head=$head: cannot read orca repo list" >&2
    exit 1
  }
  repo_resolve_err=$(mktemp "${TMPDIR:-/tmp}/on-worker-done-repo.err.XXXXXX")
  if ! orca_repo_id=$(python3 - "$repo_list_json" "$repo_root_physical" 2>"$repo_resolve_err" <<'PYREPO'
import json, os, sys

try:
    payload = json.loads(sys.argv[1])
    repos = payload.get("result", {}).get("repos")
    if not isinstance(repos, list):
        raise ValueError("repos array required")
except (TypeError, ValueError, json.JSONDecodeError):
    print("invalid orca repo list", file=sys.stderr)
    sys.exit(1)
target = os.path.realpath(sys.argv[2])
for entry in repos:
    if entry.get("kind") != "git":
        continue
    path, repo_id = entry.get("path"), entry.get("id")
    if not isinstance(path, str) or not isinstance(repo_id, str):
        continue
    try:
        if os.path.realpath(path) == target:
            print(repo_id)
            sys.exit(0)
    except OSError:
        continue
print(f"no registered Orca repo for checkout {target}", file=sys.stderr)
sys.exit(1)
PYREPO
  ); then
    resolve_msg=$(tr '\n' ' ' < "$repo_resolve_err")
    rm -f "$repo_resolve_err"
    echo "QA start refused head=$head: ${resolve_msg:-cannot resolve registered repo}" >&2
    exit 1
  fi
  rm -f "$repo_resolve_err"
  if [ "$admission_repo_id" != "$orca_repo_id" ]; then
    echo "QA start refused head=$head: admission repo_id does not match local checkout" >&2
    exit 1
  fi
else
  orca_repo_id=$admission_repo_id
fi
repo_selector="id:$orca_repo_id"
from_handle=${ORCA_TERMINAL_HANDLE:-}
[ -n "$from_handle" ] || {
  echo "QA start refused head=$head: missing ORCA_TERMINAL_HANDLE" >&2
  exit 1
}
[ -n "$ver_model" ] || {
  echo "QA start refused head=$head: usage gate did not name a reviewer model" >&2
  exit 1
}
if [ "$verifier_provider" = cursor ]; then
  [ "$ver_model" != "composer-2.5" ] || {
    echo "QA start refused head=$head: Cursor reviewer must not use composer-2.5" >&2
    exit 1
  }
  qa_name="reviewer-pr-$pr"
  cursor_start=${ON_WORKER_DONE_CURSOR_START:-$_here/start-cursor-worker.sh}
  start_args=(bash "$cursor_start" --run "$run" --spec "$brief" --title "reviewer - PR $pr"
    --model "$ver_model" --from "$from_handle" --name "$qa_name" --repo "$repo_selector" --base-branch "$pr_branch")
  [ "${#host_flags[@]}" -eq 0 ] || start_args+=("${host_flags[@]}")
  printf '%q ' "${start_args[@]}"; echo
  [ "$dry" = 1 ] && exit 0
  exec "${start_args[@]}"
fi
# shellcheck disable=SC2086
cmd="$orca orchestration worker-start --run $run --spec \"\$(cat $brief)\" --worktree $worktree_selector --task-title \"reviewer - PR $pr\" ${host_flags[*]+"${host_flags[@]}"} $flags --json"
echo "$cmd"
[ "$dry" = 1 ] && exit 0
# shellcheck disable=SC2086
exec $orca orchestration worker-start --run "$run" --spec "$(cat "$brief")" --worktree "$worktree_selector" --task-title "reviewer - PR $pr" ${host_flags[@]+"${host_flags[@]}"} $flags --json
