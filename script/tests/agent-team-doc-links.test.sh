#!/usr/bin/env bash
# After agent-team.sh project, every relative markdown link in the generated docs/agents/*.md
# must resolve inside the project (#788).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

P="$TMP/proj"
mkdir -p "$P"
printf '# Agents\n' > "$P/AGENTS.md"
git -C "$P" init -q -b main
git -C "$P" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$P" -c user.email=t@example.invalid -c user.name=t commit -qm init

if ! out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P" --project-name x 2>&1)"; then
  echo "FAIL project run (out: $(tail -5 <<<"$out"))"
  exit 1
fi

broken=""
for f in "$P"/docs/agents/*.md; do
  while IFS= read -r link; do
    target="${link%%#*}"
    [ -n "$target" ] || continue
    [ -e "$(dirname "$f")/$target" ] || broken="$broken ${f#"$P"/}->$link"
  done < <(sed 's/`[^`]*`//g' "$f" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^(https?:|mailto:|#)')
done

if [ -z "$broken" ]; then
  echo "ok   every relative link in docs/agents/*.md resolves"
else
  echo "FAIL broken links:$broken"
  exit 1
fi
