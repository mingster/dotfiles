#!/usr/bin/env bash
# Tests for link-agent-team-roles.sh
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/link-agent-team-roles.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ROLES=(elon architect-pm fullstack-dev qa-sdet release-manager sales-marketing secops-finops support-csm)

seed_dotfiles() {
  rm -rf "$tmp/dotfiles" "$tmp/proj"
  mkdir -p "$tmp/dotfiles/templates/agent-team/.claude/agents"
  for r in "${ROLES[@]}"; do
    printf 'role %s\n' "$r" > "$tmp/dotfiles/templates/agent-team/.claude/agents/$r.md"
  done
  git init -q "$tmp/proj"
}

run() { DOTFILES="$tmp/dotfiles" bash "$script" "$@" 2>&1; }

seed_dotfiles
run "$tmp/proj" >/dev/null; rc=$?
canon=$(cd "$tmp/dotfiles" && pwd -P)
if [ "$rc" = 0 ]; then
  for r in "${ROLES[@]}"; do
    dest="$tmp/proj/.claude/agents/$r.md"
    [ -L "$dest" ] && [ "$(readlink "$dest")" = "$canon/templates/agent-team/.claude/agents/$r.md" ] \
      && ok "link $r" || bad "link $r" "$(ls -la "$dest" 2>/dev/null)"
  done
  grep -qxF '.claude/agents/elon.md' "$tmp/proj/.gitignore" \
    && grep -qxF '.claude/agents/support-csm.md' "$tmp/proj/.gitignore" \
    && ok "gitignore block" || bad "gitignore block" "$(tail -12 "$tmp/proj/.gitignore" 2>/dev/null)"
else
  bad "link run exits 0" "rc=$rc"
fi

seed_dotfiles
run "$tmp/proj" >/dev/null
run "$tmp/proj" >/dev/null
n=$(grep -c '^\.claude/agents/' "$tmp/proj/.gitignore" || true)
[ "$n" = 8 ] && ok "gitignore idempotent" || bad "gitignore idempotent" "count=$n"

seed_dotfiles
mkdir -p "$tmp/proj/.claude/agents"
printf 'custom\n' > "$tmp/proj/.claude/agents/fullstack-dev.md"
out=$(run "$tmp/proj"); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qi 'refus' && echo "$out" | grep -q 'fullstack-dev' \
  && ok "refuses regular file" || bad "refuses regular file" "rc=$rc $out"

seed_dotfiles
mkdir -p "$tmp/proj/docs/agents" "$tmp/proj/.claude/agents"
printf 'facts\n' > "$tmp/proj/docs/agents/team-facts.md"
printf 'tracked\n' > "$tmp/proj/.claude/agents/qa-sdet.md"
git -C "$tmp/proj" add .claude/agents/qa-sdet.md
out=$(DOTFILES="$tmp/dotfiles" bash "$here/team-audit.sh" "$tmp/proj" 2>&1); rc=$?
echo "$out" | grep -q 'FINDING role-tracked' && echo "$out" | grep -q 'qa-sdet' \
  && ok "audit role-tracked" || bad "audit role-tracked" "$out"

seed_dotfiles
mkdir -p "$tmp/proj/docs/agents"
printf 'facts\n' > "$tmp/proj/docs/agents/team-facts.md"
out=$(DOTFILES="$tmp/dotfiles" bash "$here/team-audit.sh" "$tmp/proj" 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q 'FINDING role-symlink' \
  && ok "audit missing symlinks" || bad "audit missing symlinks" "rc=$rc $out"

seed_dotfiles
mkdir -p "$tmp/proj/docs/agents"
printf 'facts\n' > "$tmp/proj/docs/agents/team-facts.md"
run "$tmp/proj" >/dev/null
rm "$tmp/proj/.claude/agents/release-manager.md"
out=$(DOTFILES="$tmp/dotfiles" bash "$here/team-audit.sh" "$tmp/proj" 2>&1)
echo "$out" | grep -q 'FINDING role-symlink:.*release-manager' \
  && ok "audit missing one symlink" || bad "audit missing one symlink" "$out"

seed_dotfiles
mkdir -p "$tmp/proj/docs/agents"
printf 'facts\n' > "$tmp/proj/docs/agents/team-facts.md"
run "$tmp/proj" >/dev/null
ln -sf /etc/hosts "$tmp/proj/.claude/agents/sales-marketing.md"
out=$(DOTFILES="$tmp/dotfiles" bash "$here/team-audit.sh" "$tmp/proj" 2>&1)
echo "$out" | grep -q 'FINDING role-symlink:.*sales-marketing' \
  && ok "audit wrong target" || bad "audit wrong target" "$out"

seed_dotfiles
mkdir -p "$tmp/proj/docs/agents"
printf 'facts\n' > "$tmp/proj/docs/agents/team-facts.md"
run "$tmp/proj" >/dev/null
rm "$tmp/proj/.claude/agents/architect-pm.md"
printf 'local\n' > "$tmp/proj/.claude/agents/architect-pm.md"
out=$(DOTFILES="$tmp/dotfiles" bash "$here/team-audit.sh" "$tmp/proj" 2>&1)
echo "$out" | grep -q 'FINDING role-symlink:.*architect-pm' \
  && ok "audit regular file" || bad "audit regular file" "$out"

seed_dotfiles
mkdir -p "$tmp/proj/docs/agents"
printf 'facts\n' > "$tmp/proj/docs/agents/team-facts.md"
run "$tmp/proj" >/dev/null
out=$(DOTFILES="$tmp/dotfiles" bash "$here/team-audit.sh" "$tmp/proj" 2>&1)
! echo "$out" | grep -qE '^FINDING role-(symlink|tracked)' \
  && ok "no role findings when linked" || bad "no role findings when linked" "$out"

seed_dotfiles
out=$(run --dry-run "$tmp/proj")
[ ! -d "$tmp/proj/.claude" ] && echo "$out" | grep -qi 'dry' \
  && ok "dry-run writes nothing" || bad "dry-run writes nothing"

echo "link-agent-team-roles: $pass passed, $fail failed"
[ "$fail" = 0 ]
