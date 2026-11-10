#!/usr/bin/env bash
# One cold review of a PR head by a fresh agent: script/pr-review.sh <pr> <head sha>.
# The agent only reads; this script alone posts, and only a well formed answer.
set -euo pipefail

REVIEW_MODEL_STRONG='^\.github/|^\.claude/hooks/|^\.orca/|^script/usage-gate\.py|^script/heavy-gate|^script/head-checks|^script/(coordinator-publication|fleet-watch|post-verdict|ship|pr-review)\.sh'
REVIEW_MODEL_MONEY='(^|/)(payment|payments|stripe|wallet|ledger|billing|subscription|secrets)'

review_model_pick() {
  REVIEW_MODEL=sonnet
  REVIEW_MODEL_DUAL=0
  if [ "${REVIEW_MODEL_HAS_REVIEW_STRONG:-0}" -eq 1 ]; then
    REVIEW_MODEL=opus
  fi
  if grep -qiE "$REVIEW_MODEL_STRONG" <<<"${REVIEW_MODEL_NAMES_MULTILINE:-}"; then
    REVIEW_MODEL=opus
  fi
  if grep -qiE "$REVIEW_MODEL_MONEY" <<<"${REVIEW_MODEL_NAMES_MULTILINE:-}"; then
    REVIEW_MODEL=opus
    REVIEW_MODEL_DUAL=1
  fi
}

review_author_family() {
  python3 - "$1" "$2" <<'PY'
import json, os, re, subprocess, sys
FAMILIES = frozenset({"claude", "gpt", "gemini", "composer", "grok"})
repo, pr = sys.argv[1], sys.argv[2]
env = (os.environ.get("AUTHOR_FAMILY") or "").strip().lower()
if env in FAMILIES:
    print(env)
    raise SystemExit(0)
out = subprocess.run(
    ["gh", "pr", "view", pr, "--repo", repo, "--json", "labels,commits"],
    capture_output=True, text=True, timeout=60, check=False,
)
if out.returncode == 0:
    try:
        payload = json.loads(out.stdout or "{}")
    except ValueError:
        payload = {}
    for label in payload.get("labels") or []:
        m = re.fullmatch(r"author-family-([a-z]+)", (label.get("name") or "").lower())
        if m and m.group(1) in FAMILIES:
            print(m.group(1))
            raise SystemExit(0)
    pat = re.compile(r"^Author-Family:\s*(\S+)", re.I | re.M)
    for commit in payload.get("commits") or []:
        body = (commit.get("messageBody") or "") + "\n" + (commit.get("messageHeadline") or "")
        for m in pat.finditer(body):
            fam = m.group(1).lower()
            if fam in FAMILIES:
                print(fam)
                raise SystemExit(0)
print("claude")
PY
}

review_prompt_build() {
  : "${REVIEW_PROMPT_PR:?REVIEW_PROMPT_PR must be set before review_prompt_build}"
  local prompt_file=${REVIEW_PROMPT_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-prompt.txt}
  if [ ! -s "$prompt_file" ]; then
    echo "review prompt file missing or empty: $prompt_file" >&2
    exit 1
  fi
  REVIEW_PROMPT=$(<"$prompt_file")
  if [ -z "${REVIEW_PROMPT//[[:space:]]/}" ]; then
    echo "review prompt file missing or empty: $prompt_file" >&2
    exit 1
  fi
  REVIEW_PROMPT=${REVIEW_PROMPT//"{{PR}}"/$REVIEW_PROMPT_PR}
}

review_run_invoke() {
  : "${REVIEW_RUN_AGENT:?}"
  : "${REVIEW_RUN_MODEL:?}"
  : "${REVIEW_RUN_PROMPT:?}"
  : "${REVIEW_RUN_WORKDIR:?}"
  local effort=()
  [ -n "${REVIEW_RUN_EFFORT:-}" ] && effort=(--effort "$REVIEW_RUN_EFFORT")
  case "$REVIEW_RUN_AGENT" in
    claude)
      (cd "$REVIEW_RUN_WORKDIR" && claude -p "$REVIEW_RUN_PROMPT" --model "$REVIEW_RUN_MODEL" \
        "${effort[@]+"${effort[@]}"}" \
        --allowedTools "Read,Grep,Glob" --disallowedTools "Bash,Edit,Write,WebFetch,WebSearch")
      ;;
    antigravity)
      (cd "$REVIEW_RUN_WORKDIR" && agy --model "$REVIEW_RUN_MODEL" --dangerously-skip-permissions \
        -p "$REVIEW_RUN_PROMPT")
      ;;
    cursor)
      local agent_cmd=agent
      command -v agent >/dev/null 2>&1 || agent_cmd=cursor-agent
      (cd "$REVIEW_RUN_WORKDIR" && "$agent_cmd" -p "$REVIEW_RUN_PROMPT" --model "$REVIEW_RUN_MODEL" \
        --mode ask)
      ;;
    *)
      echo "unsupported review agent: $REVIEW_RUN_AGENT" >&2
      return 1
      ;;
  esac
}

pr=${1:-}
head=${2:-}
repo=${GITHUB_REPOSITORY:-}
if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
[ -n "$repo" ] || { echo "cannot resolve repository" >&2; exit 1; }

pr_review_usage_error() {
  echo "usage: $0 <pr> <head sha>" >&2
  echo "when pr is empty, head must be a 40-character commit SHA" >&2
  exit 1
}

is_40_hex_sha() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{40}$ ]]
}

skip_merged_or_closed_pr() {
  echo "PR already merged or closed; skipping review"
  exit 0
}

if [ -z "$pr" ]; then
  if ! is_40_hex_sha "$head"; then
    pr_review_usage_error
  fi
  head_lc=$(printf '%s' "$head" | tr '[:upper:]' '[:lower:]')
  pr_list_json=$(
    gh pr list --repo "$repo" --search "$head" --state all --json number,state,headRefOid
  )
  pr=$(
    jq -r --arg h "$head_lc" \
      '[.[] | select((.headRefOid | ascii_downcase) == $h)] | .[0].number // empty' <<<"$pr_list_json"
  )
  resolved_state=$(
    jq -r --arg h "$head_lc" \
      '[.[] | select((.headRefOid | ascii_downcase) == $h)] | .[0].state // empty' <<<"$pr_list_json"
  )
  if [ -z "$pr" ] || [ "$resolved_state" = "MERGED" ] || [ "$resolved_state" = "CLOSED" ]; then
    skip_merged_or_closed_pr
  fi
fi

post_review_status() {
  local state=$1
  case "${REVIEW_POST_STATUS:-}" in
    1 | true | yes) ;;
    *) return 0 ;;
  esac
  gh api --method POST "repos/$repo/statuses/$head" -f state="$state" -f context=review -f description="Independent PR review"
}

pr_head_json=$(gh pr view "$pr" --repo "$repo" --json headRefOid,state)
pr_state=$(jq -r .state <<<"$pr_head_json")
case "$pr_state" in
  MERGED | CLOSED) skip_merged_or_closed_pr ;;
esac
current=$(jq -r .headRefOid <<<"$pr_head_json")
[ "$current" = "$head" ] || { echo "stale head, a newer run reviews this PR"; exit 0; }

review_me=$(
  gh api user --jq .login 2>/dev/null ||
    { [ -n "${GITHUB_ACTOR:-}" ] && printf '%s' "$GITHUB_ACTOR"; } ||
    true
)
if [ -z "${review_me:-}" ]; then
  echo "cannot resolve reviewer login (gh api user failed and GITHUB_ACTOR empty)" >&2
  exit 1
fi

issue_comments_json=$(
  gh api --paginate "repos/$repo/issues/$pr/comments" |
    jq --arg login "$review_me" \
      '[.[] | select(.user.login == $login) | select(.created_at == .updated_at)] | sort_by(.created_at)'
) || issue_comments_json='[]'
comments=$(
  jq -r '.[].body // ""' <<<"$issue_comments_json"
)

newest_head_verdict_json=$(
  jq -n --argjson ic "$issue_comments_json" '
    reduce ($ic | sort_by(.created_at) | .[].body) as $body (
      {};
      ($body // "" | split("\n") | .[0] // "") as $line |
      if ($line | test("^Review: |^Verdict: ")) then
        (try ($line | capture("head=(?<h>[0-9a-fA-F]{40})") | .h | ascii_downcase) catch empty) as $h |
        if ($h | length) == 40 then
          if ($line | test("^Review: FAIL|^Verdict: FAIL")) then
            .[$h] = { kind: "FAIL", line: $line }
          elif ($line | test("^Review: PASS|^Verdict: PASS")) then
            .[$h] = { kind: "PASS", line: $line }
          else
            .
          end
        else
          .
        end
      else
        .
      end
    )
  '
)

any_fail_blocks_carry=$(jq -n --argjson v "$newest_head_verdict_json" '($v | to_entries | map(select(.value.kind == "FAIL")) | length)')

nv_kind=$(jq -r --arg h "$head" '.[$h | ascii_downcase].kind // empty' <<<"$newest_head_verdict_json")
case "${nv_kind:-}" in
  FAIL | PASS)
    echo "head already reviewed" >&1
    exit 0
    ;;
esac

has_review_strong=0
if gh pr view "$pr" --repo "$repo" --json labels --jq '.labels[].name' | grep -qx 'review-strong'; then
  has_review_strong=1
fi

last_pass_patch_id=
pass_line_num=0
line_num=0
fail_after_pass=
while IFS= read -r c_line || [ -n "$c_line" ]; do
  line_num=$((line_num + 1))
  case "$c_line" in
    Review:\ PASS\ head=* | Verdict:\ PASS\ head=* | Verdict:\ PASS+NOTES\ head=*)
      case "$c_line" in *patch=*)
        last_pass_patch_id=${c_line##*patch=}
        last_pass_patch_id=${last_pass_patch_id%% *}
        pass_line_num=$line_num
        fail_after_pass=
        ;;
      esac
      ;;
    Review:\ FAIL* | Verdict:\ FAIL*)
      if [ -n "$last_pass_patch_id" ] && [ "$line_num" -gt "$pass_line_num" ]; then
        fail_after_pass=1
      fi
      ;;
  esac
done <<<"$comments"

carry_same_patch=0
current_patch_id=
if [ -n "$last_pass_patch_id" ] && [ -z "${fail_after_pass:-}" ] && [ "${any_fail_blocks_carry:-0}" -eq 0 ] && [ "$has_review_strong" -eq 0 ]; then
  current_patch_id=$(gh pr diff "$pr" --repo "$repo" | git patch-id --verbatim | awk 'NF { print $1; exit }')
  if [ -n "$current_patch_id" ] && [ "$current_patch_id" = "$last_pass_patch_id" ]; then
    carry_same_patch=1
  fi
fi

if [ "$carry_same_patch" -eq 1 ]; then
  post_review_status success
  review_f=$(mktemp)
  trap 'rm -f "$review_f"' EXIT
  {
    echo "Review: PASS head=$head model=carried patch=$current_patch_id"
  } >"$review_f"
  gh pr comment "$pr" --repo "$repo" --body-file "$review_f"
  exit 0
fi

names=$(
  {
    gh pr diff "$pr" --repo "$repo" --name-only
    gh pr diff "$pr" --repo "$repo" | sed -n 's/^rename from \(.*\)$/\1/p'
    ( gh api "repos/$repo/pulls/$pr/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null ) || true
  } | sed '/^$/d' | sort -u
)

docs_only=1
while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  case "$f" in
    docs/* | changelog.d/*) ;;
    *) docs_only=0 ;;
  esac
done <<<"$names"

skill_md='(^|/)(skills/[^/]+/SKILL\.md|.agents/skills/[^/]+/SKILL\.md)$'
if [ "$docs_only" -eq 1 ] && [ -n "$names" ] && ! grep -qE "$skill_md" <<<"$names" && [ "$has_review_strong" -eq 0 ]; then
  post_review_status success
  review_f=$(mktemp)
  trap 'rm -f "$review_f"' EXIT
  docs_patch=$(gh pr diff "$pr" --repo "$repo" | git patch-id --verbatim | awk 'NF { print $1; exit }')
  {
    if [ -n "$docs_patch" ]; then
      echo "Review: PASS head=$head model=none patch=$docs_patch"
    else
      echo "Review: PASS head=$head model=none"
    fi
  } >"$review_f"
  gh pr comment "$pr" --repo "$repo" --body-file "$review_f"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/head"
gh pr view "$pr" --repo "$repo" --json title,body >"$work/pr.json"
issues=$(gh pr view "$pr" --repo "$repo" --json closingIssuesReferences --jq '.closingIssuesReferences[].number')
for issue in $issues; do gh issue view "$issue" --repo "$repo" --json number,title,body; done >"$work/issues.json" 2>/dev/null || : >"$work/issues.json"
gh pr diff "$pr" --repo "$repo" >"$work/diff.patch"
gh api "repos/$repo/tarball/$head" | tar -xz --strip-components=1 -C "$work/head"

REVIEW_MODEL_HAS_REVIEW_STRONG=$has_review_strong
REVIEW_MODEL_NAMES_MULTILINE=$names
review_model_pick

author_family=$(review_author_family "$repo" "$pr")
gate=${REVIEW_USAGE_GATE:-$HOME/dotfiles/script/usage-gate.py}
pick_flags=""
if [ -x "$gate" ] || [ -f "$gate" ]; then
  pick_flags=$("$gate" pick --role reviewer --avoid-family "$author_family" 2>/dev/null) || pick_flags=""
fi
if [ -z "$pick_flags" ]; then
  echo "cross-family reviewer unavailable" >&2
  exit 1
fi
read -r review_agent review_model review_effort < <(python3 - "$pick_flags" <<'PY'
import shlex, sys
tokens = shlex.split(sys.argv[1])
agent = model = effort = ""
i = 0
while i < len(tokens):
    if tokens[i] == "--agent" and i + 1 < len(tokens):
        agent = tokens[i + 1]
        i += 2
        continue
    if tokens[i] == "--model" and i + 1 < len(tokens):
        model = tokens[i + 1]
        i += 2
        continue
    if tokens[i] == "--effort" and i + 1 < len(tokens):
        effort = tokens[i + 1]
        i += 2
        continue
    i += 1
print(f"{agent} {model} {effort}")
PY
)
[ -n "$review_agent" ] && [ -n "$review_model" ] || {
  echo "usage gate returned no reviewer" >&2
  exit 1
}
if [ "$review_agent" = claude ] && { [ "$REVIEW_MODEL" = opus ] || [ "$has_review_strong" -eq 1 ]; }; then
  review_model=opus
  review_effort=${review_effort:-medium}
fi
model=$review_model

REVIEW_PROMPT_PR="$pr"
review_prompt_build
prompt=$REVIEW_PROMPT

run_cold_review() {
  REVIEW_RUN_AGENT=$review_agent
  REVIEW_RUN_MODEL=$review_model
  REVIEW_RUN_EFFORT=${review_effort:-}
  REVIEW_RUN_PROMPT=$prompt
  REVIEW_RUN_WORKDIR=$work
  review_run_invoke
}

answer=$(run_cold_review)
verdict=$(grep -m1 -E '^Review: (PASS|FAIL)$' <<<"$answer") || {
  echo "malformed review answer" >&2
  exit 1
}

if [ "${REVIEW_MODEL_DUAL:-0}" -eq 1 ]; then
  answer2=$(run_cold_review)
  verdict2=$(grep -m1 -E '^Review: (PASS|FAIL)$' <<<"$answer2") || {
    echo "malformed second review answer" >&2
    exit 1
  }
  if [ "$verdict" != "$verdict2" ]; then
    disagree_first=$verdict
    disagree_second=$verdict2
    verdict="Review: FAIL"
    answer=$(
      {
        echo "$verdict"
        echo "The two money reviews disagreed ($disagree_first vs $disagree_second); treating as FAIL."
        echo "--- first run ---"
        awk -v v="$disagree_first" '$0 == v && !seen { seen = 1; next } seen' <<<"$answer"
        echo "--- second run ---"
        awk -v v="$disagree_second" '$0 == v && !seen { seen = 1; next } seen' <<<"$answer2"
      }
    )
  else
    answer=$answer2
  fi
fi

pass_patch=$(gh pr diff "$pr" --repo "$repo" | git patch-id --verbatim | awk 'NF { print $1; exit }')
{
  if [ -n "$pass_patch" ]; then
    echo "$verdict head=$head model=$model patch=$pass_patch"
  else
    echo "$verdict head=$head model=$model"
  fi
  awk -v v="$verdict" '$0 == v && !seen { seen = 1; next } seen' <<<"$answer"
} >"$work/review.md"

if [ "$verdict" = "Review: PASS" ]; then
  post_review_status success
else
  post_review_status failure
  failed=$(
    jq '[.[] | (.body // "" | split("\n")[0]) | select(test("^Review: FAIL\\s|^Verdict: FAIL\\s"))] | length' \
      <<<"$issue_comments_json"
  )
  if [ "${failed:-0}" -ge 2 ]; then gh pr edit "$pr" --repo "$repo" --add-label needs-elon; fi
fi
gh pr comment "$pr" --repo "$repo" --body-file "$work/review.md"
