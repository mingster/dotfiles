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

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
