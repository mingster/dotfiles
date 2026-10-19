#!/usr/bin/env bash
# The Tech Lead's only way to merge a reviewed PR.
# Usage: lead-merge.sh --repo owner/name --pr N --head <sha>
set -euo pipefail

die() { echo "lead-merge: refused: $*" >&2; exit 1; }

repo="" pr="" head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --pr) pr="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$repo" ] && [ -n "$pr" ] && [ -n "$head" ] || die "usage: lead-merge.sh --repo owner/name --pr N --head <sha>"
case "$pr" in *[!0-9]*) die "--pr must be a number" ;; esac

# 1. Caller is the lead. Orca sets no role variable (ORCA_TERMINAL_HANDLE and
# ORCA_AGENT_SESSION_ID exist for every agent), so the worktree name is the check.
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git worktree"
top=$(cd -P "$top" && pwd)
root=$(cd -P "$HOME/orca/workspaces" 2>/dev/null && pwd) || die "no $HOME/orca/workspaces"
case "$top" in "$root"/*) ;; *) die "worktree is not under $root" ;; esac
case "$(basename "$top")" in lead-*) ;; *) die "only the lead worktree (lead-*) may merge" ;; esac

# 2. PR state
info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefName,headRefOid,mergeable,url,changedFiles,body,comments,baseRefOid) \
  || die "cannot read PR $pr"
field() { jq -r "$1" <<<"$info"; }
[ "$(field .state)" = OPEN ] || die "PR $pr is not open"
[ "$(field .baseRefName)" = main ] || die "PR $pr base is not main"
[ "$(field .headRefOid)" = "$head" ] || die "PR $pr head is $(field .headRefOid), not $head"
[ "$(field .mergeable)" = MERGEABLE ] || die "PR $pr is not MERGEABLE"

# 4. Head branch
case "$(field .headRefName)" in main|staging|production) die "head branch $(field .headRefName) is not mergeable here" ;; esac

# gh pr view truncates files at 100; every path gate shares this complete list.
file_pages=$(gh api --paginate "repos/$repo/pulls/$pr/files") || die "cannot read complete PR files"
files=$(jq -s '[.[][] | .filename]' <<<"$file_pages") || die "invalid PR file inventory"
[ "$(jq length <<<"$files")" = "$(field .changedFiles)" ] || die "PR file count differs from changed_files"

# 3. Owner only paths
while IFS= read -r f; do
  case "$f" in
    .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|.codex/*|*/.codex/*|*.rules)
      die "PR touches $f, which waits for the owner through Elon" ;;
  esac
done < <(jq -r '.[]' <<<"$files")
diff=$(gh pr diff "$pr" --repo "$repo") || die "cannot read diff of PR $pr"
if awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//)} intent && /^\+Status:.*Accepted/{found=1} END{exit !found}' <<<"$diff"; then
  die "PR accepts an intent under docs/intent/, which waits for the owner through Elon"
fi

# 5. Verification is required even for documentation changes.
# Normalize heading case, spacing and trailing punctuation once for both gates.
normalized_body=$(field .body | awk '
/^[[:blank:]]*#+[[:space:]]/ {
  heading=$0; sub(/^[[:blank:]]*/, "", heading)
  hashes=heading; sub(/[[:space:]].*$/, "", hashes)
  title=heading; sub(/^#+[[:space:]]+/, "", title)
  gsub(/[[:space:]]+/, " ", title)
  sub(/[[:space:][:punct:]]+$/, "", title)
  print hashes " " tolower(title); next
}
{print}')
grep -qE '^## verification$' <<<"$normalized_body" || die "missing ## Verification heading"
if grep -qiE '^#{1,6} test plan$' <<<"$normalized_body"; then die "Test plan heading is forbidden"; fi
bullet_count=$(awk '/^## verification$/ {inside=1; next} inside && /^#+ / {inside=0} inside && /^[[:space:]]*[-*+] / {n++} END {print n+0}' <<<"$normalized_body")
[ "$bullet_count" -ge 1 ] && [ "$bullet_count" -le 3 ] || die "Verification needs 1 to 3 run and outcome bullets"
check_body=$(jq -r --arg head "$head" '[.comments[].body | select((split("\n")[0]) == ("Checks: PASS head="+$head) or (split("\n")[0]) == ("Checks: FAIL head="+$head))] | last // ""' <<<"$info")
checks=${check_body%%$'\n'*}
[ "$checks" = "Checks: PASS head=$head" ] || die "missing current-head Checks: PASS"
unchecked=false
if grep -q '^Unchecked paths: .' <<<"$check_body"; then unchecked=true; fi
docs_only=true
while IFS= read -r f; do
  case "$f" in
    .claude/agents/*|*/.claude/agents/*|.agents/skills/*|*/.agents/skills/*) docs_only=false ;;
    docs/*|*.md|changelog.d/*) ;;
    *) docs_only=false ;;
  esac
done < <(jq -r '.[]' <<<"$files")

lane=normal
sensitive=false
base=$(field .baseRefOid)
if [[ "$base" =~ ^[0-9a-f]{40}$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
  for ref in "$base" "$head"; do
    git cat-file -e "$ref^{commit}" 2>/dev/null || git fetch origin "$ref" >&2 || die "cannot inspect copy-only diff"
  done
  classification=$(python3 - "$base" "$head" "$files" "$(dirname "$0")/copy-only.config.json" <<'PYTHON'
import html
from html.parser import HTMLParser
import json
import re
import subprocess
import sys
import unicodedata

base, head, inventory, config = sys.argv[1:]
def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode()
class VisibleText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
    def handle_data(self, data):
        self.parts.append(data)
def visible_folded(text):
    text.encode("utf-8", errors="strict")
    parser = VisibleText()
    parser.feed(html.unescape(text))
    parser.close()
    decomposed = unicodedata.normalize("NFKD", "".join(parser.parts))
    unmarked = "".join(char for char in decomposed if not unicodedata.category(char).startswith("M"))
    folded = unicodedata.normalize("NFKC", unmarked).casefold()
    return folded
def normalize(text):
    return "".join(char for char in visible_folded(text) if unicodedata.category(char)[0] in "LN")
def term_counts(text):
    normalized, visible = normalize(text), visible_folded(text)
    # Preserve currency symbols: NT$ must never become the ordinary substring nt.
    return [visible.count(visible_folded(raw))
            if any(unicodedata.category(char) == "Sc" or char == "%" for char in raw) or not word
            else normalized.count(word) for raw, word in zip(words, normalized_words)]
def contains_topic(text):
    return any(term_counts(text))
def increased(before, after):
    return any(new > old for old, new in zip(term_counts(before), term_counts(after)))
def quantities(values):
    # Compare tokens per value so independent locale keys cannot assemble numbers.
    from collections import Counter
    return Counter(token for value in values for token in
                   re.findall(r"\d+|NT\$|\$|¥|元|円|USD|TWD|JPY|%", html.unescape(value), re.IGNORECASE))
def flatten(value, path=()):
    if isinstance(value, str):
        return {path: value}
    if not isinstance(value, dict) or not value:
        raise ValueError("not a translation object")
    result = {}
    for key, child in value.items():
        result.update(flatten(child, (*path, key)))
    return result
try:
    ancestor = git("merge-base", base, head).strip()
    paths = git("diff", "--name-only", "-z", "--no-renames", ancestor, head, "--").split("\0")[:-1]
    eligible = bool(paths) and sorted(paths) == sorted(json.loads(inventory))
    groups = json.load(open(config))["sensitive_word_groups"]
    if not isinstance(groups, dict) or not groups:
        raise ValueError("invalid sensitive wording groups")
    # Group metadata documents provenance; only explicit word arrays are matched.
    words = []
    for locales in groups.values():
        if not isinstance(locales, dict) or set(locales) != {"en", "tw", "jp"}:
            raise ValueError("invalid sensitive wording locales")
        for group in locales.values():
            if not isinstance(group, dict) or not isinstance(group.get("words"), list) or not group["words"]:
                raise ValueError("invalid sensitive wording group")
            words.extend(group["words"])
    if not isinstance(words, list) or not words or any(not isinstance(word, str) or not word.strip() for word in words):
        raise ValueError("invalid sensitive wording policy")
    normalized_words = [normalize(word) for word in words]
    sensitive = False
    for path in paths:
        entry = git("diff", "--raw", "-z", "--no-renames", ancestor, head, "--", path).split("\0")
        if len(entry) != 3 or entry[1] != path or entry[2]:
            raise ValueError("unknown diff entry")
        raw = entry[0].split()
        if len(raw) != 5:
            raise ValueError("unknown diff metadata")
        if raw[4] not in ("A", "M") or raw[0] not in (":100644", ":100755", ":000000") or raw[1] not in ("100644", "100755"):
            eligible = False
        stats = git("diff", "--numstat", "-z", "--no-renames", ancestor, head, "--", path).split("\t", 2)
        if len(stats) != 3 or "-" in stats[:2]:
            eligible = False
        if re.fullmatch(r"web/src/app/i18n/locales/(tw|en|jp)/[^/]+\.json", path):
            if raw[4] != "M":
                eligible = False
            before = {} if raw[4] == "A" else flatten(json.loads(git("show", f"{ancestor}:{path}")))
            after = {} if raw[4] == "D" else flatten(json.loads(git("show", f"{head}:{path}")))
            if before.keys() != after.keys():
                eligible = False
            changed = [key for key in before.keys() | after.keys()
                       if before.get(key) != after.get(key)]
            # Added/deleted keys still retain the owner gate; only unchanged
            # key context is ignored when both values are ordinary UI wording.
            sensitive |= any(contains_topic(" ".join(key)) for key in
                             before.keys() ^ after.keys())
            # Unchanged key context alone cannot make an ordinary label sensitive.
            sensitive |= any(contains_topic(before.get(key, "")) or
                             contains_topic(after.get(key, "")) for key in changed)
            sensitive |= quantities(before[key] for key in changed if key in before) != quantities(
                after[key] for key in changed if key in after)
            before, after = "".join(before.values()), "".join(after.values())
        elif re.fullmatch(r"marketing/(content|copy)/(?:[^/]+/)*[^/]+\.(md|txt)", path):
            # Absent files and gitlinks contain no text blob on that side.
            before = "" if raw[4] == "A" or raw[0] == ":160000" else git("show", f"{ancestor}:{path}")
            after = "" if raw[4] == "D" or raw[1] == "160000" else git("show", f"{head}:{path}")
            sensitive |= contains_topic(before) or contains_topic(after)
            sensitive |= quantities([before]) != quantities([after])
        else:
            eligible = False
            continue
        # Whole-file counts include retained context and reordered locale values.
        sensitive |= increased(before, after)
    if sensitive:
        eligible = False
    print(("copy-only" if eligible else "normal") + (" sensitive" if sensitive else ""))
except (ValueError, KeyError, OSError, subprocess.SubprocessError):
    # Copy changes with unreadable blobs or policy still need the owner gate.
    copy_changed = any(path.startswith(("web/src/app/i18n/locales/", "marketing/content/", "marketing/copy/"))
                       for path in json.loads(inventory))
    print("normal sensitive" if copy_changed else "normal")
PYTHON
) || die "cannot classify copy-only diff"
  case "$classification" in
    copy-only) lane=copy-only ;;
    'copy-only sensitive') lane=copy-only; sensitive=true ;;
    'normal sensitive') sensitive=true ;;
  esac
fi
# Recompute both patches; never trust a patch-id asserted in a comment.
patch_id() {
  local sha="$1" base patch
  base=$(field .baseRefOid)
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 1
  for ref in "$base" "$sha"; do
    git cat-file -e "$ref^{commit}" 2>/dev/null || git fetch origin "$ref" >&2 || return 1
  done
  patch=$(git diff "$base...$sha" -- | git patch-id --stable) || return 1
  [ -n "$patch" ] || return 1
  awk 'NR == 1 {print $1}' <<<"$patch"
}
verdict_head="$head"
# Dispatch ids Orca knows about, read lazily and once, following page cursors.
known_dispatches=""
load_dispatches() {
  local orca="${ORCA_CLI_COMMAND:-orca}" cursor="" page run n m runs=""
  # worker-list without --run sees only the caller's bound run, so read every run.
  for n in $(seq 1 50); do
    page=$("$orca" orchestration run-list --limit 100 ${cursor:+--cursor "$cursor"} --json 2>/dev/null) \
      || die "cannot read orca run-list to verify verdict dispatch ids"
    runs+=$(jq -r '.result.runs[]?.id' <<<"$page" 2>/dev/null)$'\n' \
      || die "cannot parse orca run-list to verify verdict dispatch ids"
    cursor=$(jq -r '.result.nextCursor // empty' <<<"$page")
    [ -n "$cursor" ] && continue
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      cursor=""
      for m in $(seq 1 50); do
        page=$("$orca" orchestration worker-list --run "$run" --limit 100 ${cursor:+--cursor "$cursor"} --json 2>/dev/null) \
          || die "cannot read orca worker-list to verify verdict dispatch ids"
        known_dispatches+=$(jq -r '.result.workers[]?.dispatchId // empty' <<<"$page" 2>/dev/null)$'\n' \
          || die "cannot parse orca worker-list to verify verdict dispatch ids"
        cursor=$(jq -r '.result.page.nextCursor // empty' <<<"$page")
        [ -n "$cursor" ] || break
      done
      [ -z "$cursor" ] || die "worker-list has too many pages to verify verdict dispatch ids"
    done <<<"$runs"
    return 0
  done
  die "run-list has too many pages to verify verdict dispatch ids"
}
if [ "$docs_only" = false ] || [ "$unchecked" = true ] || [ "$lane" = copy-only ]; then
  current_patch=""
  applicable=()
  passes=0 fails=0
  # Every Verdict for this head (or an equal patch) counts. Newest first; none
  # of them can erase another, and an edited or minimized one fails closed.
  while IFS= read -r row; do
    comment=$(jq -r '@base64d | fromjson | .body' <<<"\"$row\"")
    flagged=$(jq -r '@base64d | fromjson | ((.includesCreatedEdit // false) or (.isMinimized // false))' <<<"\"$row\"")
    line=${comment%%$'\n'*}
    if [[ "$line" =~ ^Verdict:\ (PASS\+NOTES|PASS|FAIL)\ head=([0-9a-f]{40})\ verifier=([a-zA-Z0-9_-]+)\ author=([a-zA-Z0-9_-]+)$ ]]; then
      verdict="${BASH_REMATCH[1]}"; candidate_head="${BASH_REMATCH[2]}"
      verifier_id="${BASH_REMATCH[3]}"; author_id="${BASH_REMATCH[4]}"
      [ "${BASH_REMATCH[3]}" != "${BASH_REMATCH[4]}" ] || die "author cannot supply verifier verdict"
      applies=false
      if [ "$candidate_head" = "$head" ]; then
        applies=true
      else
        current_patch="${current_patch:-$(patch_id "$head")}" || die "cannot compute head patch-id for verdict"
        old_patch=$(patch_id "$candidate_head") || continue
        [ "$old_patch" != "$current_patch" ] || applies=true
      fi
      if [ "$applies" = true ]; then
        [ -n "$known_dispatches" ] || load_dispatches
        grep -Fxq -- "$verifier_id" <<<"$known_dispatches" || die "verdict verifier $verifier_id is not a known dispatch"
        # author=unknown is the one literal allowed without a dispatch; any other author must be known.
        [ "$author_id" = unknown ] || grep -Fxq -- "$author_id" <<<"$known_dispatches" || die "verdict author $author_id is not a known dispatch"
        [ "$flagged" = false ] || die "verdict comment was edited or minimized; post a fresh Verdict"
        [ ${#applicable[@]} -gt 0 ] || verdict_head="$candidate_head"
        applicable+=("$verdict"$'\n'"$comment")
        if [ "$verdict" = FAIL ]; then fails=$((fails+1)); else passes=$((passes+1)); fi
      fi
    fi
  done < <(jq -r '.comments | reverse[] | @json | @base64' <<<"$info")
  [ "$passes" -gt 0 ] || die "missing passing verifier verdict for current head or stable patch-id"
  [ "$fails" -eq 0 ] || die "conflicting PASS and FAIL verdicts for current head or stable patch-id"
  for entry in "${applicable[@]}"; do
    comment=${entry#*$'\n'}
    if [ "$unchecked" = true ] && ! grep -qi 'unchecked' <<<"$comment"; then
      die "verdict must cover unchecked paths in its live lane"
    fi
    # The topic attestation belongs to an independent Verdict, never a separate
    # comment. Any owner attestation keeps the owner gate on.
    topics=$(printf '%s\n' "$comment" | sed -n '2p')
    case "$topics" in
      'Copy topics: owner') sensitive=true; lane=normal ;;
      'Copy topics: none') ;;
      *) lane=normal ;;
    esac
  done
  if [ "$lane" = copy-only ]; then
    for entry in "${applicable[@]}"; do
      comment=${entry#*$'\n'}
      for evidence in 'screenshots?' 'phone[ -]width' '\btw\b' '\ben\b' '\bjp\b'; do
        grep -qiE "$evidence" <<<"${comment#*$'\n'}" || die "copy-only verdict needs phone-width screenshots in tw, en and jp"
      done
    done
  fi
fi

echo "lead-merge: lane=$lane"
if [ "$sensitive" = true ]; then
  # Owner Copy approval is `bin/owner-approve.sh copy <sha>`, a terminal-only file.
  # No GitHub comment approves anything: every agent's gh login is the owner's.
  ns=$(sed -n 's/^APPROVAL_NAMESPACE *= *"\([a-z0-9_-]*\)".*/\1/p' "$top/.claude/hooks/guard-bash.py" 2>/dev/null | head -n1)
  [ -n "$ns" ] || ns=$(jq -r '.approval_namespace // empty' "$(dirname "$0")/copy-only.config.json" 2>/dev/null) || ns=""
  [ -n "$ns" ] || die "no approval namespace (APPROVAL_NAMESPACE in .claude/hooks/guard-bash.py or approval_namespace in copy-only.config.json)"
  approval_file="$HOME/.config/$ns/approval.json"
  jq -e --arg head "$head" --argjson now "$(date +%s)" \
    '(if type == "object" and has("approvals") then .approvals else [.] end) | any(.[]; .scope == "copy" and .target == $head and (.expires_at | type == "number") and .expires_at > $now and .expires_at <= $now + 1860)' \
    "$approval_file" >/dev/null 2>&1 \
    || die "missing owner copy approval for current head (owner runs: bin/owner-approve.sh copy $head)"
fi

# Gate changes need a fresh, head-bound countersign from Elon.
triggers=$(awk '/^\+[^+]/ && /\.skip\(|\.only\(|test\.todo([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_.])xit\(|eslint-disable|biome-ignore|@ts-ignore|@ts-expect-error/ {print}' <<<"$diff")
while IFS= read -r f; do
  case "$f" in
    .agents/head-checks.conf|*/.agents/head-checks.conf|script/lead-merge.sh|*/script/lead-merge.sh|script/copy-only.config.json|*/script/copy-only.config.json)
      gate_lines=$(awk -v path="$f" '/^\+\+\+ / {active=($0 == "+++ b/" path)} active && /^[+-]/ && !/^\+\+\+ / && !/^--- / {print path ":" $0}' <<<"$diff")
      triggers="${triggers}${triggers:+$'\n'}${gate_lines:-gate definition changed: $f}" ;;
  esac
done < <(jq -r '.[]' <<<"$files")
if [ -n "$triggers" ]; then
  echo "lead-merge: countersign triggers:" >&2
  printf '%s\n' "$triggers" >&2
  jq -e --arg prefix "Countersign: Elon head=$head reason=" \
    'any(.comments[].body; startswith($prefix) and (.[($prefix|length):] | test("[^[:space:]]")))' <<<"$info" >/dev/null \
    || die "missing Countersign: Elon for current head"
fi

# Fetch immediately before merge; any shared changed path needs a new exact-head run.
git fetch origin main >&2 || die "cannot fetch main; rebase and rerun head-checks"
ancestor=$(git merge-base "$(field .baseRefOid)" "$verdict_head") || die "cannot find merge base; rebase and rerun head-checks"
trunk_files=$(git diff --name-only "$ancestor" origin/main --) || die "cannot inspect trunk drift"
while IFS= read -r f; do
  if grep -Fxq -- "$f" <<<"$trunk_files"; then die "trunk changed $f; rebase and rerun head-checks"; fi
done < <(jq -r '.[]' <<<"$files")

merge() { gh pr merge "$pr" --repo "$repo" --merge --match-head-commit "$head"; }
if ! out=$(merge 2>&1); then
  out=$(merge 2>&1) || { echo "lead-merge: merge failed: $out" >&2; exit 1; }
fi

final=$(gh pr view "$pr" --repo "$repo" --json state,mergeCommit,url) || { echo "lead-merge: cannot confirm merge of PR $pr" >&2; exit 1; }
[ "$(jq -r .state <<<"$final")" = MERGED ] || { echo "lead-merge: PR $pr is not MERGED after merge" >&2; exit 1; }
merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"$final")
[ -n "$merge_sha" ] || die "MERGED read-back has no merge commit"
echo "MERGED $(jq -r .url <<<"$final") $merge_sha"

# Cleanup after the merge: head branch, ticket lanes, old recovery branches. Never fails the merge.
# Issue N: "Closes #N" in the PR body, else the first number in the branch name. DRY_RUN=1 previews.
head_branch=$(field .headRefName)
issue=$(field .body | sed -nE 's/.*[Cc]loses[[:space:]]+#([0-9]+).*/\1/p' | head -n1)
[ -n "$issue" ] || issue=$(sed -nE 's/[^0-9]*([0-9]+).*/\1/p' <<<"$head_branch" | head -n1)
bash "$(dirname "$0")/merge-cleanup.sh" --branch "$head_branch" ${issue:+--issue "$issue"} ${pr:+--pr "$pr"} \
  || echo "lead-merge: cleanup incomplete (merge succeeded); run script/wrap-up.sh" >&2
