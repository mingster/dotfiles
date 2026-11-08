#!/usr/bin/env bash
# Offline CLI test: a protected hand merge needs approval newer than its head.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view 7 --repo example/repo --json headRefOid,comments')
    jq -n --argjson comments "$COMMENTS" '{headRefOid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", comments:$comments}' ;;
  'api repos/example/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    echo '{"commit":{"committer":{"date":"2026-10-28T01:00:00Z"}}}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOS
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
passed=0
check() {
  local name=$1 expected=$2 code=0 out
  export COMMENTS=$3
  out=$(bash "$here/protected-merge-check.sh" example/repo 7 2>&1) || code=$?
  if [ "$code" != "$expected" ] || ! grep -q "$4" <<<"$out"; then
    printf 'FAIL %s (exit %s)\n%s\n' "$name" "$code" "$out"
    exit 1
  fi
  echo "ok $name"
  passed=$((passed+1))
}
check 'no comment refuses' 1 '[]' 'Owner go'
check 'comment older than head refuses' 1 '[{"body":"Owner go approved","createdAt":"2026-10-28T00:59:59Z"}]' 'Owner go'
check 'fresh comment allows' 0 '[{"body":"Owner go approved\nMerge the protected change.","createdAt":"2026-10-28T01:00:01Z"}]' 'Owner go'
echo "passed $passed, failed 0"
