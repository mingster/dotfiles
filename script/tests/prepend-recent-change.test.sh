#!/usr/bin/env bash
# Tests for prepend-recent-change.ts against a temp repo. Needs bun. bash 3.2 compatible.
here=$(cd "$(dirname "$0")" && pwd)
tool="$here/../prepend-recent-change.ts"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

repo="$tmp/repo"
mkdir -p "$repo/.git" "$repo/.cursor"
echo '{"changelog":"HOME.md"}' > "$repo/.cursor/changelog-hook.json"
note="$repo/HOME.md"
run() { (cd "$repo" && bun "$tool" "$@" 2>&1); }
args=(--link n1 --label L --summary S --date 2026-01-02)

# 1. prepended under the heading, text after the bullets kept
printf '# Home\n\n## Recent Changes\n- 2025-12-31 old\n\n## Other\nkeep me\n' > "$note"
out=$(run "${args[@]}"); rc=$?
check "prepend exits 0" "$([ $rc = 0 ]; echo $?)"
check "line sits right under the heading" "$([ "$(sed -n 4p "$note")" = '- 2026-01-02 — [[n1|L]] — S' ]; echo $?)"
check "old bullet kept after it" "$([ "$(sed -n 5p "$note")" = '- 2025-12-31 old' ]; echo $?)"
check "text after the bullet block is kept" "$(grep -q '^## Other$' "$note" && grep -q '^keep me$' "$note"; echo $?)"
check "heading not duplicated" "$([ "$(grep -c '^## Recent Changes$' "$note")" = 1 ]; echo $?)"

# 2. same line again is a no op
before=$(cat "$note"); out=$(run "${args[@]}")
check "duplicate line leaves the file unchanged" "$([ "$(cat "$note")" = "$before" ] && echo "$out" | grep -q 'already contains'; echo $?)"

# 3. trimmed to 10 bullets
{ printf '## Recent Changes\n'; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf -- '- 2025-01-%02d e%s\n' "$i" "$i"; done; printf '\ntail\n'; } > "$note"
run "${args[@]}" >/dev/null
check "list cut to 10 lines" "$([ "$(grep -c '^- ' "$note")" = 10 ]; echo $?)"
check "newest first, oldest dropped" "$(sed -n 2p "$note" | grep -q 'n1|L' && ! grep -q ' e10$' "$note" && grep -q ' e9$' "$note"; echo $?)"
check "tail after trim kept" "$(grep -q '^tail$' "$note"; echo $?)"

# 4. CRLF stays CRLF
printf '## Recent Changes\r\n- 2025-12-31 old\r\n\r\n## Other\r\nkeep\r\n' > "$note"
run "${args[@]}" >/dev/null
check "CRLF file stays CRLF (no bare LF)" "$([ "$(wc -l < "$note")" -eq "$(grep -c $'\r$' "$note")" ]; echo $?)"

# 5. missing heading exits 1 and leaves the file alone
printf '# Home\nno heading here\n' > "$note"; before=$(cat "$note")
out=$(run "${args[@]}"); rc=$?
check "missing heading exits 1 with a message" "$([ $rc = 1 ] && echo "$out" | grep -q 'Missing "## Recent Changes"'; echo $?)"
check "missing heading leaves the file unchanged" "$([ "$(cat "$note")" = "$before" ]; echo $?)"

# 6. missing flags exit 1 with usage
printf '## Recent Changes\n- x\n' > "$note"
for drop in link label summary; do
  case $drop in
    link) a=(--label L --summary S) ;;
    label) a=(--link n1 --summary S) ;;
    summary) a=(--link n1 --label L) ;;
  esac
  out=$(run "${a[@]}"); rc=$?
  check "missing --$drop exits 1 with usage" "$([ $rc = 1 ] && echo "$out" | grep -q '^Usage:'; echo $?)"
done

# 7. a flag given as a value
out=$(run --link --label x --summary S); rc=$?
check "--link --label x exits 1 with usage" "$([ $rc = 1 ] && echo "$out" | grep -q '^Usage:'; echo $?)"
check "flag as value leaves the file unchanged" "$([ "$(cat "$note")" = "$(printf '## Recent Changes\n- x\n')" ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
