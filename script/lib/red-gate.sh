#!/usr/bin/env bash
# Red gate issues (#1745, #1746). Source it. One open issue titled "red gate: <tool>" per broken gate tool,
# labelled P1 and ready-for-agent, so fleet-watch starts one fixer on it ahead of other work.
# RED_GATE_GH names the gh command (tests inject a stub).

red_gate_gh() { "${RED_GATE_GH:-gh}" "$@"; }

# red_gate_repo <checkout dir>: owner/name of the GitHub origin, empty when origin is not on github.com.
red_gate_repo() {
  local url
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then printf '%s\n' "${BASH_REMATCH[1]%.git}"; fi
}

# red_gate_find <repo> <tool>: number of the open issue with the exact title, empty when none.
red_gate_find() {
  local title="red gate: $2"
  red_gate_gh issue list --repo "$1" --state open --search "\"$title\" in:title" --json number,title --limit 20 2>/dev/null \
    | jq -r --arg t "$title" '[.[] | select(.title == $t)][0].number // empty' 2>/dev/null || true
}

# red_gate_file <repo> <tool> <detail text>: file the issue, or comment on the open one. Prints the number.
# Returns 1 when gh fails. The detail is cut and scrubbed of database URLs and secret looking values first.
red_gate_file() {
  local repo=$1 tool=$2 detail number body
  detail=$(printf '%s' "$3" | LC_ALL=C sed -E 's#(postgres(ql)?|mysql|mongodb(\+srv)?|redis|sqlserver)://[^[:space:]]+#[redacted database URL]#g' | tail -c 3000)
  number=$(red_gate_find "$repo" "$tool")
  if [ -n "$number" ]; then
    red_gate_gh issue comment "$number" --repo "$repo" --body "Failed again:

$detail" >/dev/null 2>&1 || return 1
    printf '%s\n' "$number"; return 0
  fi
  body=$(printf 'The gate tool `%s` is broken for a reason that is not a PR. While this issue is open, other PRs that hit only this gate wait with `blocked by red gate #<n>` and do not retry it.\n\nFailing output:\n\n```\n%s\n```\n\n## Acceptance\n- [ ] `%s` works again; the fix names the cause above.\n- [ ] The PR body has the line `Fixes red gate: #<this issue>`.\n- [ ] bash script/checks-local.sh exits 0.\n\n## Out of scope\nTest failures of other PRs and unrelated cleanup.\n' "$tool" "$detail" "$tool")
  number=$(red_gate_gh issue create --repo "$repo" --title "red gate: $tool" --body "$body" --label P1 --label ready-for-agent 2>/dev/null | tail -1) || return 1
  number=${number##*/}
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$number"
}
