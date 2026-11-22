#!/usr/bin/env bash
# link-cursor-hooks.sh, link-cursor-user.sh, backup-claude-desktop.sh: -h/--help print usage and write
# nothing, any other argument exits 2 and writes nothing, no argument still does the job.
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$(dirname "$0")/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
t() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

# Fresh HOME and DOTFILES per case, so "nothing written" is a check of the whole tree.
fresh() {
  rm -rf "$tmp/h" "$tmp/d"
  mkdir -p "$tmp/h/Library/Application Support/Claude" "$tmp/h/.config/Claude" "$tmp/d/ide/cursor/hooks" "$tmp/d/init" "$tmp/d/script/lib"
  printf '{"hooks":{}}\n' >"$tmp/d/ide/cursor/hooks.json"
  printf '#!/bin/sh\n' >"$tmp/d/ide/cursor/hooks/a.sh"
  for f in settings.json keybindings.json environment.json; do printf '{}\n' >"$tmp/d/ide/cursor/$f"; done
  cp "$here/lib/link-user-file.sh" "$tmp/d/script/lib/"
  printf '{"preferences":{}}\n' >"$tmp/h/Library/Application Support/Claude/claude_desktop_config.json"
  printf '{"preferences":{}}\n' >"$tmp/h/.config/Claude/claude_desktop_config.json"
}
snap() { (cd "$tmp" && find h d | sort && find h d -type f -exec cksum {} + | sort); }
run() { HOME="$tmp/h" DOTFILES="$tmp/d" XDG_CONFIG_HOME="$tmp/h/.config" /bin/bash "$here/$1" "${@:2}" 2>&1; }

for s in link-cursor-hooks.sh link-cursor-user.sh backup-claude-desktop.sh; do
  for flag in -h --help; do
    fresh; before=$(snap)
    out=$(run "$s" "$flag"); code=$?
    t "$s $flag: usage, exit 0" '[ "$code" = 0 ] && echo "$out" | grep -qi "^usage:"'
    t "$s $flag: writes nothing" '[ "$(snap)" = "$before" ]'
  done
  for flag in --dry-run -x extra; do
    fresh; before=$(snap)
    out=$(run "$s" "$flag"); code=$?
    t "$s $flag: usage, exit 2" '[ "$code" = 2 ] && echo "$out" | grep -qi "^usage:"'
    t "$s $flag: writes nothing" '[ "$(snap)" = "$before" ]'
  done
  fresh
  out=$(run "$s"); code=$?
  t "$s no argument: still runs" '[ "$code" = 0 ] && ! echo "$out" | grep -qi "^usage:"'
done
fresh; run link-cursor-hooks.sh >/dev/null
t "link-cursor-hooks.sh no argument copies hooks.json" '[ -f "$tmp/h/.cursor/hooks.json" ]'
fresh; run backup-claude-desktop.sh >/dev/null
t "backup-claude-desktop.sh no argument writes the config" '[ -f "$tmp/d/init/claude_desktop_config.json" ]'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
