#!/usr/bin/env bash
# template-sync-pr.sh opens one pin bump PR per project after a template merge (#1247).
# gh is a stub; git is real except that origin reports a GitHub URL, while pushes go to a local bare repo.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMP/bin"
git config --global user.name t
git config --global user.email t@example.invalid
git config --global init.defaultBranch main

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || echo "$2"; }

REAL_GIT=$(command -v git)
cat >"$TMP/bin/git" <<EOF
#!/usr/bin/env bash
# Report a GitHub origin for the project checkout, so the script derives example-org/proj.
args=("\$@")
if [ "\${args[0]}" = -C ] && [ "\${args[2]}" = remote ] && [ "\${args[3]}" = get-url ] && [ "\${args[4]:-}" = origin ]; then
  case "\$("$REAL_GIT" -C "\${args[1]}" remote get-url origin)" in
    *proj.git) echo https://github.com/example-org/proj.git; exit 0 ;;
  esac
fi
exec "$REAL_GIT" "\$@"
EOF
GH_LOG="$TMP/gh.log"
cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$GH_LOG"
case "\$1 \$2" in
  "pr list") [ -f "$TMP/open-pr" ] && cat "$TMP/open-pr"; exit 0 ;;
  "pr create") for a in "\$@"; do [ "\$p" = --body ] && printf '%s\n' "\$a" >"$TMP/pr-body"; p=\$a; done; echo 42 >"$TMP/open-pr"; echo https://github.com/example-org/proj/pull/42 ;;
  "pr checks") cat "$TMP/checks" ;;
esac
EOF
chmod +x "$TMP/bin/git" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# dotfiles fixture with an origin, so origin/main is the pin template-sync-pr.sh renders from.
DF="$TMP/dotfiles"
mkdir -p "$DF"
cp -R "$ROOT/script" "$ROOT/templates" "$ROOT/.agents" "$DF/"
git init -q "$DF" && git -C "$DF" add -A && git -C "$DF" commit -qm X
git init -q --bare "$TMP/dotfiles.git"
git -C "$DF" remote add origin "$TMP/dotfiles.git" && git -C "$DF" push -q origin main && git -C "$DF" fetch -q origin

# A project already synced at X and pushed.
git init -q --bare "$TMP/proj.git"
git clone -q "$TMP/proj.git" "$TMP/proj" 2>/dev/null
PROJ="$TMP/proj"
printf '# Proj\n' >"$PROJ/AGENTS.md"
DOTFILES="$DF" bash "$DF/script/agent-team.sh" sync "$PROJ" >/dev/null 2>&1
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm sync && git -C "$PROJ" push -q origin main

export TEMPLATE_SYNC_STATE="$TMP/state.json" TEMPLATE_SYNC_POLL=0 TEMPLATE_SYNC_WAIT=0
run() { OUT=$(bash "$DF/script/template-sync-pr.sh" --verdict-from example-org/dotfiles#5 --project "$PROJ" "$@" 2>&1); RC=$?; }

run --no-ship
if [ "$RC" -eq 0 ] && grep -qx 'example-org/proj none -' <<<"$OUT" && ! grep -q 'pr create' "$GH_LOG" 2>/dev/null; then
  ok "no diff opens nothing"
else bad "no diff opens nothing" "rc=$RC out=$OUT gh=$(cat "$GH_LOG" 2>/dev/null)"; fi
[ "$(git -C "$PROJ" worktree list --porcelain | grep -c '^worktree')" = 1 ] && ok "the project worktree is removed" || bad "the project worktree is removed" "$(git -C "$PROJ" worktree list)"

# A template change lands on dotfiles main.
printf '\nA template change.\n' >>"$DF/templates/agent-team/docs/agents/team.md"
git -C "$DF" commit -qam Y && git -C "$DF" push -q origin main
Y=$(git -C "$DF" rev-parse HEAD)
run --no-ship
if [ "$RC" -eq 0 ] && grep -qx 'example-org/proj open 42' <<<"$OUT" && [ "$(grep -c 'pr create' "$GH_LOG")" = 1 ]; then
  ok "a template change opens one bump PR"
else bad "a template change opens one bump PR" "rc=$RC out=$OUT gh=$(cat "$GH_LOG")"; fi
pushed_pin=$(git -C "$TMP/proj.git" show "team-sync/$Y:.claude/agent-team-pin" 2>/dev/null)
[ "$pushed_pin" = "$Y" ] && ok "the bump branch is team-sync/<sha> and pins that sha" || bad "the bump branch is team-sync/<sha> and pins that sha" "pin=$pushed_pin"

# The bump PR body passes the PR body gate ship.sh applies, and the script builder is not the verifier's family (#1291).
if grep -qx 'Builder: agent=script model=template-sync-pr.sh' "$TMP/pr-body" && grep -qx '## Self-check' "$TMP/pr-body" \
  && python3 "$ROOT/script/pr-body-gate.py" <"$TMP/pr-body" \
  && [ "$(python3 "$ROOT/script/usage-gate.py" family --agent script --model template-sync-pr.sh)" != claude ]; then
  ok "the bump PR body passes the Builder and Self-check checks"
else bad "the bump PR body passes the Builder and Self-check checks" "$(cat "$TMP/pr-body" 2>/dev/null)"; fi

run --no-ship
if [ "$RC" -eq 0 ] && grep -qx 'example-org/proj open 42' <<<"$OUT" && [ "$(grep -c 'pr create' "$GH_LOG")" = 1 ]; then
  ok "a rerun reuses the open PR"
else bad "a rerun reuses the open PR" "rc=$RC out=$OUT gh=$(cat "$GH_LOG")"; fi

# Red checks are recorded for fleet-watch and nothing ships.
echo '[{"bucket":"fail"}]' >"$TMP/checks"
run
if [ "$RC" -ne 0 ] && grep -qx 'example-org/proj red 42' <<<"$OUT" \
  && [ "$(jq -r '."example-org/proj".state' "$TEMPLATE_SYNC_STATE")" = red ] && ! grep -q 'pr merge' "$GH_LOG"; then
  ok "red checks are recorded and nothing ships"
else bad "red checks are recorded and nothing ships" "rc=$RC out=$OUT state=$(cat "$TEMPLATE_SYNC_STATE" 2>/dev/null)"; fi
[ "$(git -C "$DF" worktree list --porcelain | grep -c '^worktree')" = 1 ] && ok "the dotfiles worktree is removed" || bad "the dotfiles worktree is removed" "$(git -C "$DF" worktree list)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
