#!/usr/bin/env bash
# List removed doc lines that no longer appear anywhere under docs/ or README.md at head.
# Usage: doc-fact-check.sh --repo <dir> --base <ref> --head <ref> [file...]
# With no files, checks every .md under README.md and docs/ that changed between base and head.
set -euo pipefail

repo="" base="" head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:-}; shift 2 ;;
    --base) base=${2:-}; shift 2 ;;
    --head) head=${2:-}; shift 2 ;;
    -h|--help) echo "Usage: doc-fact-check.sh --repo <dir> --base <ref> --head <ref> [file...]" >&2; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
files=("$@")

die() { echo "doc-fact-check: $*" >&2; exit 1; }
[ -n "$repo" ] && [ -d "$repo/.git" ] || die "--repo must be a git checkout"
[ -n "$base" ] && [ -n "$head" ] || die "--base and --head are required"

repo=$(cd "$repo" && pwd)
git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin "$base" 2>/dev/null || true
git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin "$head" 2>/dev/null || true
git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null || die "cannot read base $base"
git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || die "cannot read head $head"

if [ "${#files[@]}" -eq 0 ]; then
  files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(git -C "$repo" diff --name-only "$base" "$head" -- README.md docs/ 2>/dev/null \
    | grep -E '(^README\.md$|\.md$)' || true)
fi

if [ "${#files[@]}" -eq 0 ]; then
  exit 0
fi

export DFC_REPO="$repo" DFC_BASE="$base" DFC_HEAD="$head"
python3 - "${files[@]}" <<'PY'
import os, re, subprocess, sys

repo = os.environ["DFC_REPO"]
base = os.environ["DFC_BASE"]
head = os.environ["DFC_HEAD"]
files = sys.argv[1:]

def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", repo, *args], text=True)

def doc_corpus() -> str:
    parts = []
    for path in ["README.md"]:
        try:
            parts.append(git("show", f"{head}:{path}"))
        except subprocess.CalledProcessError:
            pass
    try:
        listed = git("ls-tree", "-r", "--name-only", head, "docs").splitlines()
    except subprocess.CalledProcessError:
        listed = []
    for path in listed:
        if not path.endswith(".md"):
            continue
        try:
            parts.append(git("show", f"{head}:{path}"))
        except subprocess.CalledProcessError:
            pass
    return "\n".join(parts)

def norm(line: str) -> str:
    line = line.rstrip("\n\r")
    line = re.sub(r"\s+", " ", line).strip()
    return line

corpus = doc_corpus()
corpus_lines = {norm(x) for x in corpus.splitlines() if norm(x)}
missing = []

for path in files:
    if path not in ("README.md",) and not (path.startswith("docs/") and path.endswith(".md")):
        continue
    try:
        diff = git("diff", "-U0", base, head, "--", path)
    except subprocess.CalledProcessError:
        continue
    for line in diff.splitlines():
        if not line.startswith("-") or line.startswith("---"):
            continue
        text = norm(line[1:])
        if len(text) < 3:
            continue
        if text in corpus_lines:
            continue
        missing.append(f"{path}: {text}")

if missing:
  for line in missing:
    print(line)
  raise SystemExit(1)
PY
