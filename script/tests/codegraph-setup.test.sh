#!/usr/bin/env bash
# codegraph-setup.sh on a temp HOME with a fake npm and a fake codegraph (no network, no real install).
# shellcheck source=script/tests/lib/asdf-pin.sh disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

export HOME="$tmp/home"
export CODEGRAPH_HOME="$tmp/cg-home"
export DOTFILES="$tmp/dotfiles"
mkdir -p "$HOME/.claude" "$HOME/.cursor" "$HOME/.gemini/config" "$DOTFILES" "$tmp/bin"
pin=$(bash "$here/codegraph-setup.sh" version)

# A fake npm: `npm ci` drops a fake codegraph into node_modules/.bin and counts the call.
cat > "$tmp/bin/npm" <<EOS
#!/usr/bin/env bash
[ "\$1" = ci ] || exit 1
echo ci >> "$tmp/npm-calls"
mkdir -p node_modules/.bin
cp "$tmp/fake-codegraph" node_modules/.bin/codegraph
chmod +x node_modules/.bin/codegraph
EOS
# The fake codegraph does what the real install does to the config files, hook and CLAUDE.md section included.
cat > "$tmp/fake-codegraph" <<EOS
#!/usr/bin/env bash
case "\$1" in
  version) echo $pin ;;
  telemetry)
    if [ "\${2:-}" = off ]; then touch "$tmp/telemetry-off"; echo "Telemetry disabled"; exit 0; fi
    [ -e "$tmp/telemetry-off" ] && echo "Telemetry: disabled (your saved choice)" || echo "Telemetry: enabled"
    ;;
  install)
    echo "\$*" >> "$tmp/install-calls"
    case "\$2" in *claude*) echo '{"mcpServers":{"codegraph":{}}}' > "\$HOME/.claude.json"
      python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p))
d["permissions"]["allow"].append("mcp__codegraph__*")
d["hooks"]["UserPromptSubmit"].append({"hooks": [{"type": "command", "command": "codegraph prompt-hook"}]})
json.dump(d, open(p, "w"), indent=2)
PY
      printf '\n<!-- CODEGRAPH_START -->\n## CodeGraph\ntext\n<!-- CODEGRAPH_END -->\n' >> "\$HOME/.claude/CLAUDE.md" ;; esac
    case "\$2" in *cursor*) echo '{"mcpServers":{"codegraph":{}}}' > "\$HOME/.cursor/mcp.json" ;; esac
    case "\$2" in *antigravity*) echo '{"mcpServers":{"codegraph":{}}}' > "\$HOME/.gemini/config/mcp_config.json" ;; esac
    ;;
  init) mkdir -p .codegraph; touch .codegraph/codegraph.db; echo "init \$PWD" >> "$tmp/init-calls" ;;
esac
EOS
chmod +x "$tmp/bin/npm" "$tmp/fake-codegraph"
export PATH="$tmp/bin:$PATH"

cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(keep:*)"]},
  "hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo orca-hook"}]}]}
}
JSON
printf '# my rules\n' > "$HOME/.claude/CLAUDE.md"
cp "$HOME/.claude/CLAUDE.md" "$tmp/CLAUDE.md.before"

out=$(bash "$here/codegraph-setup.sh" machine --dry-run 2>&1)
check "machine --dry-run plans the install and wiring" "$(echo "$out" | grep -q 'would install codegraph' && echo "$out" | grep -q 'would run codegraph install --target=claude,cursor,antigravity'; echo $?)"
check "machine --dry-run writes nothing" "$([ ! -e "$CODEGRAPH_HOME" ] && [ ! -e "$HOME/.local" ] && [ ! -e "$tmp/npm-calls" ] && [ ! -e "$HOME/.cursor/mcp.json" ]; echo $?)"

bash "$here/codegraph-setup.sh" machine >"$tmp/run1.out" 2>&1
check "machine installs the pin with npm ci" "$([ "$(wc -l < "$tmp/npm-calls" | tr -d " ")" = 1 ] && [ -x "$CODEGRAPH_HOME/$pin/node_modules/.bin/codegraph" ]; echo $?)"
check "machine links codegraph into ~/.local/bin" "$([ "$(readlink "$HOME/.local/bin/codegraph")" = "$CODEGRAPH_HOME/$pin/node_modules/.bin/codegraph" ]; echo $?)"
check "machine turns telemetry off" "$([ -e "$tmp/telemetry-off" ]; echo $?)"
check "machine wires Claude Code, Cursor and Antigravity" \
  "$([ -f "$HOME/.claude.json" ] && [ -f "$HOME/.cursor/mcp.json" ] && [ -f "$HOME/.gemini/config/mcp_config.json" ]; echo $?)"
check "machine keeps the mcp__codegraph__ permission and the existing settings" \
  "$(python3 -I -c 'import json,os; d=json.load(open(os.path.expanduser("~/.claude/settings.json"))); a=d["permissions"]["allow"]; assert "mcp__codegraph__*" in a and "Bash(keep:*)" in a; assert d["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]=="echo orca-hook"' ; echo $?)"
hook='$HOME/.local/bin/codegraph prompt-hook'
count_hooks() { python3 -I -c 'import json,os,sys; d=json.load(open(os.path.expanduser("~/.claude/settings.json"))); print(sum(1 for g in d.get("hooks",{}).get("UserPromptSubmit",[]) for h in g["hooks"] if h["command"]==sys.argv[1]))' "$hook"; }
check "machine installs one UserPromptSubmit hook that runs the pinned link" "$([ "$(count_hooks)" = 1 ]; echo $?)"
check "machine replaces the bare codegraph prompt-hook the installer added" \
  "$(! grep -q '"codegraph prompt-hook"' "$HOME/.claude/settings.json" && grep -q 'hook set in' "$tmp/run1.out"; echo $?)"
check "machine keeps the other UserPromptSubmit hooks" "$(grep -q 'echo orca-hook' "$HOME/.claude/settings.json"; echo $?)"
check "machine removes the codegraph section from CLAUDE.md" "$(cmp -s "$HOME/.claude/CLAUDE.md" "$tmp/CLAUDE.md.before"; echo $?)"

out2=$(bash "$here/codegraph-setup.sh" machine 2>&1)
check "a second machine run prints nothing" "$([ -z "$out2" ]; echo $?)"
check "a second machine run does not reinstall or rewire" \
  "$([ "$(wc -l < "$tmp/npm-calls" | tr -d " ")" = 1 ] && [ "$(wc -l < "$tmp/install-calls" | tr -d " ")" = 1 ]; echo $?)"

# A bare hook added later is swapped for the pinned one, and a missing hook comes back, even when the agents are wired.
python3 -I -c 'import json,os; p=os.path.expanduser("~/.claude/settings.json"); d=json.load(open(p)); d["hooks"]["UserPromptSubmit"].append({"hooks":[{"type":"command","command":"codegraph prompt-hook"}]}); json.dump(d,open(p,"w"))'
bash "$here/codegraph-setup.sh" machine >/dev/null 2>&1
check "a bare hook added later is replaced by the pinned one" "$(! grep -q '"codegraph prompt-hook"' "$HOME/.claude/settings.json" && [ "$(count_hooks)" = 1 ]; echo $?)"
python3 -I -c 'import json,os; p=os.path.expanduser("~/.claude/settings.json"); d=json.load(open(p)); d["hooks"]["UserPromptSubmit"]=[g for g in d["hooks"]["UserPromptSubmit"] if "codegraph" not in g["hooks"][0]["command"]]; json.dump(d,open(p,"w"))'
bash "$here/codegraph-setup.sh" machine >/dev/null 2>&1
check "a removed hook is put back on the next run" "$([ "$(count_hooks)" = 1 ]; echo $?)"

# uninstall
out=$(bash "$here/codegraph-setup.sh" uninstall --dry-run 2>&1)
check "uninstall --dry-run plans and removes nothing" "$(echo "$out" | grep -q 'would remove' && [ "$(count_hooks)" = 1 ] && [ -L "$HOME/.local/bin/codegraph" ]; echo $?)"
bash "$here/codegraph-setup.sh" uninstall >"$tmp/un.out" 2>&1
check "uninstall removes the codegraph hook and keeps the other hook" \
  "$(! grep -q 'codegraph' "$HOME/.claude/settings.json" && grep -q 'echo orca-hook' "$HOME/.claude/settings.json" && grep -q 'Bash(keep:\*)' "$HOME/.claude/settings.json"; echo $?)"
check "uninstall removes the MCP entries and the link" \
  "$(! grep -q codegraph "$HOME/.claude.json" "$HOME/.cursor/mcp.json" "$HOME/.gemini/config/mcp_config.json" && [ ! -e "$HOME/.local/bin/codegraph" ]; echo $?)"
out=$(bash "$here/codegraph-setup.sh" uninstall 2>&1)
check "a second uninstall prints nothing" "$([ -z "$out" ]; echo $?)"
bash "$here/codegraph-setup.sh" machine >/dev/null 2>&1
check "machine after uninstall installs the hook again" "$([ "$(count_hooks)" = 1 ]; echo $?)"

# project
proj="$tmp/proj"; mkdir -p "$proj"; proj=$(cd "$proj" && pwd -P); git -C "$proj" init -q
git -C "$proj" -c user.email=a@b -c user.name=n commit -q --allow-empty -m init
out=$(bash "$here/codegraph-setup.sh" project "$proj" --dry-run 2>&1)
check "project --dry-run plans the index and writes nothing" "$(echo "$out" | grep -q "would index $proj" && [ ! -e "$proj/.codegraph" ]; echo $?)"
bash "$here/codegraph-setup.sh" project "$proj" >/dev/null 2>&1
check "project indexes the directory" "$([ -f "$proj/.codegraph/codegraph.db" ]; echo $?)"
check "project keeps .codegraph/ out of git without touching tracked files" \
  "$(grep -qxF '.codegraph/' "$proj/.git/info/exclude" && [ -z "$(git -C "$proj" status --porcelain)" ]; echo $?)"
out=$(bash "$here/codegraph-setup.sh" project "$proj" 2>&1)
check "a second project run prints nothing and indexes once" "$([ -z "$out" ] && [ "$(wc -l < "$tmp/init-calls" | tr -d " ")" = 1 ]; echo $?)"

git -C "$proj" worktree add -q "$tmp/wt" -b wt
out=$(bash "$here/codegraph-setup.sh" project "$tmp/wt" 2>&1)
check "a linked worktree is skipped, not indexed" "$(echo "$out" | grep -q 'linked worktree' && [ ! -e "$tmp/wt/.codegraph" ]; echo $?)"
check "the exclude entry covers the worktree too" "$([ -z "$(git -C "$tmp/wt" status --porcelain)" ]; echo $?)"

check "project without a directory fails" "$(bash "$here/codegraph-setup.sh" project >/dev/null 2>&1; [ $? -ne 0 ]; echo $?)"
check "the pin is an exact version" "$(echo "$pin" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; echo $?)"
check "the lockfile pins every platform tarball with an integrity hash" \
  "$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1]))["packages"]; n=[k for k in p if "codegraph" in k]; assert len(n)>=2 and all(p[k]["integrity"].startswith("sha512-") for k in n)' "$here/codegraph/package-lock.json"; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
