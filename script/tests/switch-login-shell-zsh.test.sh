#!/usr/bin/env bash
# switch-login-shell-zsh.sh links the zsh files, calls chsh only when the login shell is not zsh, then prints the tool paths.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/script/switch-login-shell-zsh.sh"
PASS=0
FAIL=0
check() {
  if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/dot"
touch "$TMP/dot/.zshenv" "$TMP/dot/.zshrc"
ln -s "$TMP/dot/stale" "$TMP/home/.p10k.zsh"

cat >"$TMP/bin/chsh" <<'STUB'
#!/usr/bin/env bash
echo "chsh $*" >>"$STUB_LOG"
STUB
cat >"$TMP/bin/zsh" <<'STUB'
#!/usr/bin/env bash
echo "zsh $*" >>"$STUB_LOG"
echo "/stub/python3"
STUB
chmod +x "$TMP/bin/chsh" "$TMP/bin/zsh"
echo "$TMP/bin/zsh" >"$TMP/shells"

run() {
  : >"$TMP/log"
  HOME="$TMP/home" SHELL="$1" PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" SHELLS_FILE="$TMP/shells" \
    bash "$SCRIPT" --dotfiles "$TMP/dot" 2>&1
}

out="$(run /usr/bin/fish)"
check "chsh runs when shell is fish" 'grep -q "^chsh -s $TMP/bin/zsh$" "$TMP/log"'
check "links .zshrc" '[ "$(readlink "$TMP/home/.zshrc")" = "$TMP/dot/.zshrc" ]'
check "links .zshenv" '[ "$(readlink "$TMP/home/.zshenv")" = "$TMP/dot/.zshenv" ]'
check "removes stale .p10k.zsh" '[ ! -e "$TMP/home/.p10k.zsh" ] && [ ! -L "$TMP/home/.p10k.zsh" ]'
check "checks tools from a fresh login zsh" 'grep -q "^zsh -lic command -v python3 node bash$" "$TMP/log"'
check "prints the tool check output" 'echo "$out" | grep -q "/stub/python3"'

run /bin/bash >/dev/null
check "chsh runs when shell is bash" 'grep -q "^chsh " "$TMP/log"'

run /bin/zsh >/dev/null
check "chsh skipped when shell is zsh" '! grep -q "^chsh " "$TMP/log"'
check "tool check still runs when shell is zsh" 'grep -q "^zsh -lic" "$TMP/log"'

# #1495: from a linked worktree with the real home, it refuses and links nothing.
MAIN="$(cd "$TMP" && pwd -P)/main"
WT="$(cd "$TMP" && pwd -P)/worker"
git init -q "$MAIN"
touch "$MAIN/.zshenv" "$MAIN/.zshrc" "$MAIN/.zlogin"
git -C "$MAIN" add -A
git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -qm seed
git -C "$MAIN" worktree add -q "$WT" -b worker
REAL="$(cd "$TMP" && pwd -P)/real-home"
mkdir -p "$REAL"
: >"$TMP/log"
rc=0
out="$(HOME="$REAL" DOTFILES_REAL_HOME="$REAL" SHELL=/usr/bin/fish PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" SHELLS_FILE="$TMP/shells" \
  bash "$SCRIPT" --dotfiles "$WT" 2>&1)" || rc=$?
check "worktree with real home exits 1" '[ "$rc" -eq 1 ]'
check "worktree refusal names the main checkout" 'echo "$out" | grep -q "switch-login-shell-zsh: refusing to wire $REAL from $WT; run it from the main checkout $MAIN"'
check "worktree refusal creates no links" '[ -z "$(ls -A "$REAL")" ]'
check "worktree refusal runs no chsh" '! grep -q "^chsh " "$TMP/log"'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
