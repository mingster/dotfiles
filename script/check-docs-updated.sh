#!/usr/bin/env bash
# A PR that changes script/ or templates/ must change a doc too, or say why not.
# Usage: check-docs-updated.sh [--body-file F | --body TEXT] (--base REF [--head REF] | --files-from F | <path>...)
# A doc is anything under docs/, README.md, RELEASE-NOTES.md, a template .md, or a .md in the same
# directory as a changed file. changelog.d/ and CHANGELOG.md never count. The PR body can opt out with
# a line `Docs: none, <reason>`. With no body given, the body comes from the open PR at HEAD_CHECK_SHA
# (set by head-checks.sh) or at --head, read with gh. Prints each problem and exits 1 when there is one.
set -euo pipefail

usage() { echo "check-docs-updated: $*" >&2; exit 2; }

base="" head="" files_from="" body="" have_body=0
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base=${2:?--base needs a ref}; shift 2 ;;
    --head) head=${2:?--head needs a ref}; shift 2 ;;
    --files-from) files_from=${2:?--files-from needs a file}; shift 2 ;;
    --body-file) body=$(cat "${2:?--body-file needs a file}"); have_body=1; shift 2 ;;
    --body) body=${2-}; have_body=1; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) usage "unknown option $1" ;;
    *) files+=("$1"); shift ;;
  esac
done

if [ -n "$base" ]; then
  mb=$(git merge-base "$base" "${head:-HEAD}") || usage "cannot resolve --base $base or --head ${head:-HEAD}"
  diff_out=$(git diff --name-only "$mb" "${head:-HEAD}") || usage "git diff failed for --base $base"
  while IFS= read -r f; do [ -z "$f" ] || files+=("$f"); done <<<"$diff_out"
fi
if [ -n "$files_from" ]; then
  [ -r "$files_from" ] || usage "cannot read --files-from $files_from"
  while IFS= read -r f; do [ -z "$f" ] || files+=("$f"); done <"$files_from"
fi

is_doc() {
  case "$1" in
    changelog.d/*|CHANGELOG.md) return 1 ;;
    docs/*|README.md|RELEASE-NOTES.md|templates/*.md) return 0 ;;
  esac
  return 1
}

code=()
docs=()
dirs=" "
for f in ${files[@]+"${files[@]}"}; do
  case "$f" in
    script/*|templates/*)
      case "$f" in *.md) ;; *) code+=("$f"); dirs="$dirs$(dirname "$f") " ;; esac ;;
  esac
  if is_doc "$f"; then docs+=("$f"); fi
done
if [ ${#code[@]} -eq 0 ]; then echo "ok   no script/ or templates/ change"; exit 0; fi
# A .md beside a changed file counts as a doc.
for f in ${files[@]+"${files[@]}"}; do
  case "$f" in
    changelog.d/*|CHANGELOG.md) ;;
    *.md) case "$dirs" in *" $(dirname "$f") "*) docs+=("$f") ;; esac ;;
  esac
done
if [ ${#docs[@]} -gt 0 ]; then echo "ok   docs changed: ${docs[0]}"; exit 0; fi

if [ "$have_body" -eq 0 ]; then
  sha=${HEAD_CHECK_SHA:-}
  [ -n "$sha" ] || { [ -z "$head" ] || sha=$(git rev-parse "$head"); }
  if [ -n "$sha" ] && command -v gh >/dev/null 2>&1; then
    body=$(gh pr list --state open --search "$sha" --json body --jq '.[0].body // ""' 2>/dev/null || true)
  fi
fi
if printf '%s\n' "$body" | grep -qE '^Docs: none, [^[:space:]]'; then
  echo "ok   PR body says: $(printf '%s\n' "$body" | grep -m1 -E '^Docs: none, [^[:space:]]')"
  exit 0
fi

echo "FAIL ${#code[@]} file(s) under script/ or templates/ changed (first: ${code[0]}) and no doc did."
echo "     Update a doc (docs/, README.md, RELEASE-NOTES.md, a .md beside the file, a template .md)"
echo "     or add the line 'Docs: none, <reason>' to the PR body. A changelog.d fragment is not a doc."
exit 1
