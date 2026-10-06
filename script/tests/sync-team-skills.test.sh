#!/usr/bin/env bash
# Tests for script/sync-team-skills.sh. Run: bash script/tests/sync-team-skills.test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/sync-team-skills.sh"
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# A fake dotfiles with two tier 2 skills, and an empty project.
new_dotfiles() {
  d="$(mktemp -d "$ROOT/dotfiles.XXXXXX")"
  s="$d/templates/agent-team/.agents/skills"
  mkdir -p "$s/alpha" "$s/beta"
  printf -- '---\nname: alpha\ndescription: Alpha.\n---\n\n# Alpha\n\nBody.\n' > "$s/alpha/SKILL.md"
  printf 'helper notes\n' > "$s/alpha/notes.md"
  printf -- '---\nname: beta\ndescription: Beta.\n---\n\nBeta body.\n' > "$s/beta/SKILL.md"
  echo "$d"
}
new_project() { d="$(mktemp -d "$ROOT/project.XXXXXX")"; git -C "$d" init -q; echo "$d"; }
sync() { DOTFILES="$1" bash "$SCRIPT" "${@:2}" 2>&1; }

# 1. sync writes each skill, stamps SKILL.md after the frontmatter, links .claude and .cursor
D="$(new_dotfiles)"; P="$(new_project)"
sync "$D" "$P" >/dev/null; rc=$?
first="$(head -1 "$P/.agents/skills/alpha/SKILL.md")"
stamp="$(sed -n 5p "$P/.agents/skills/alpha/SKILL.md")"
[ "$rc" -eq 0 ] && [ "$first" = "---" ] \
  && echo "$stamp" | grep -q 'Generated from dotfiles templates/agent-team/.agents/skills/alpha' \
  && echo "$stamp" | grep -q 'do not edit' \
  && echo "$stamp" | grep -Eq 'source-sha256: [0-9a-f]{64}' \
  && [ "$(cat "$P/.agents/skills/alpha/notes.md")" = "helper notes" ] \
  && [ "$(readlink "$P/.claude/skills/alpha")" = "../../.agents/skills/alpha" ] \
  && [ "$(readlink "$P/.cursor/skills/beta")" = "../../.agents/skills/beta" ] \
  && pass "sync writes stamped copies and links" || bad "sync writes stamped copies and links (rc $rc, stamp: $stamp)"

# 2. clean copy passes --check
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -eq 0 ] && pass "clean copy passes --check" || bad "clean copy passes --check: $out"

# 3. a second sync changes nothing
tree() { (cd "$1" && find . -path ./.git -prune -o \( -type f -print -exec cat {} \; \) -o \( -type l -print -exec readlink {} \; \) | shasum); }
snap="$(tree "$P")"
sync "$D" "$P" >/dev/null
[ "$snap" = "$(tree "$P")" ] \
  && pass "idempotent" || bad "idempotent"

# 4. a hand edited copy fails --check and names the file
echo "local tweak" >> "$P/.agents/skills/alpha/SKILL.md"
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'alpha/SKILL.md' \
  && pass "edited copy fails --check" || bad "edited copy fails --check (rc $rc): $out"

# 5. sync restores it, then a hand edited helper file fails too
sync "$D" "$P" >/dev/null
echo "x" >> "$P/.agents/skills/alpha/notes.md"
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'alpha/notes.md' \
  && pass "edited helper fails --check" || bad "edited helper fails --check (rc $rc): $out"

# 6. a missing copy fails --check
sync "$D" "$P" >/dev/null
rm -rf "$P/.agents/skills/beta"
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'beta' \
  && pass "missing copy fails --check" || bad "missing copy fails --check (rc $rc): $out"

# 7. an extra file in a generated skill fails --check
sync "$D" "$P" >/dev/null
echo "stray" > "$P/.agents/skills/beta/extra.md"
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'beta/extra.md' \
  && pass "extra file fails --check" || bad "extra file fails --check (rc $rc): $out"

# 8. sync removes the extra file
sync "$D" "$P" >/dev/null
[ ! -e "$P/.agents/skills/beta/extra.md" ] && pass "sync removes extra file" || bad "sync removes extra file"

# 9. a changed dotfiles source makes the project copy fail --check (out of date)
printf 'new line\n' >> "$D/templates/agent-team/.agents/skills/beta/SKILL.md"
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'beta/SKILL.md' \
  && pass "stale copy fails --check" || bad "stale copy fails --check (rc $rc): $out"

# 10. the stamp hash changes with the source
old="$(grep -o 'source-sha256: [0-9a-f]*' "$P/.agents/skills/beta/SKILL.md")"
sync "$D" "$P" >/dev/null
new="$(grep -o 'source-sha256: [0-9a-f]*' "$P/.agents/skills/beta/SKILL.md")"
[ -n "$old" ] && [ "$old" != "$new" ] && pass "hash follows source" || bad "hash follows source ($old / $new)"

# 11. a missing .claude link fails --check
rm "$P/.claude/skills/alpha"
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q '.claude/skills/alpha' \
  && pass "missing link fails --check" || bad "missing link fails --check (rc $rc): $out"

# 12. sync refuses to replace a hand written skill (no stamp) unless --force
D="$(new_dotfiles)"; P="$(new_project)"
mkdir -p "$P/.agents/skills/alpha"
printf -- '---\nname: alpha\n---\nhand written\n' > "$P/.agents/skills/alpha/SKILL.md"
printf 'product facts\n' > "$P/.agents/skills/alpha/facts.md"
out="$(sync "$D" "$P")"; rc=$?
[ "$rc" -ne 0 ] && [ -e "$P/.agents/skills/alpha/facts.md" ] && echo "$out" | grep -q -- '--force' \
  && pass "refuses hand written copy" || bad "refuses hand written copy (rc $rc): $out"
sync "$D" --force "$P" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$P/.agents/skills/alpha/facts.md" ] \
  && grep -q 'source-sha256' "$P/.agents/skills/alpha/SKILL.md" \
  && pass "--force replaces hand written copy" || bad "--force replaces hand written copy (rc $rc)"

# 13. sync refuses a real directory where a link belongs
D="$(new_dotfiles)"; P="$(new_project)"
mkdir -p "$P/.cursor/skills/alpha"
out="$(sync "$D" "$P")"; rc=$?
[ "$rc" -ne 0 ] && [ -d "$P/.cursor/skills/alpha" ] && [ ! -L "$P/.cursor/skills/alpha" ] \
  && echo "$out" | grep -q '.cursor/skills/alpha' \
  && pass "refuses real dir at link path" || bad "refuses real dir at link path (rc $rc): $out"

# 14. missing dotfiles source exits non zero
P="$(new_project)"
out="$(DOTFILES=/nonexistent bash "$SCRIPT" "$P" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "missing dotfiles fails" || bad "missing dotfiles fails"

# 15. a skill removed from dotfiles: --check flags the stale copy, sync removes it and its links
D="$(new_dotfiles)"; P="$(new_project)"
sync "$D" "$P" >/dev/null
rm -rf "$D/templates/agent-team/.agents/skills/beta"
out="$(sync "$D" --check "$P")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'beta' \
  && pass "removed skill fails --check" || bad "removed skill fails --check (rc $rc): $out"
sync "$D" "$P" >/dev/null
[ ! -e "$P/.agents/skills/beta" ] && [ ! -L "$P/.claude/skills/beta" ] && [ ! -L "$P/.cursor/skills/beta" ] \
  && [ -d "$P/.agents/skills/alpha" ] && sync "$D" --check "$P" >/dev/null \
  && pass "sync removes removed skill" || bad "sync removes removed skill"

# 16. a hand written skill unknown to dotfiles is left alone
mkdir -p "$P/.agents/skills/local"; echo "x" > "$P/.agents/skills/local/SKILL.md"
sync "$D" "$P" >/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ -f "$P/.agents/skills/local/SKILL.md" ] && sync "$D" --check "$P" >/dev/null \
  && pass "project skill untouched" || bad "project skill untouched (rc $rc)"

# 17. refuses a target whose skills folder resolves outside it (a home folder linked into dotfiles)
D="$(new_dotfiles)"; H="$(mktemp -d "$ROOT/home.XXXXXX")"
mkdir -p "$D/.agents/skills/tdd"; echo tdd > "$D/.agents/skills/tdd/SKILL.md"
ln -s "$D/.agents" "$H/.agents"
out="$(sync "$D" "$H")"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/.agents/skills/alpha" ] && echo "$out" | grep -q 'outside' \
  && pass "refuses skills folder outside the project" || bad "refuses skills folder outside the project (rc $rc): $out"

# 18. refuses the dotfiles checkout itself
out="$(sync "$D" "$D")"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/.agents/skills/alpha" ] \
  && pass "refuses dotfiles as target" || bad "refuses dotfiles as target (rc $rc): $out"

exit "$fail"
