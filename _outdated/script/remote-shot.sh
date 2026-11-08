#!/usr/bin/env bash
# Run a capture spec remotely, with an explicit database guard, and fetch PNGs.
# The env file stays on the remote host; only its database host/name are printed.
set -euo pipefail
usage() {
  echo 'usage: remote-shot.sh --host H --repo-dir R --dir D --sub S --gate G --spec SPEC --env-file REMOTE_ENV --expect-db DB --out LOCAL_DIR [--weight 2]' >&2
  exit 64
}
host='' repo_dir='' dir='' sub='' gate='' spec='' env_file='' expect_db='' out='' weight=2
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --host) host="$2" ;;
    --repo-dir) repo_dir="$2" ;;
    --dir) dir="$2" ;;
    --sub) sub="$2" ;;
    --gate) gate="$2" ;;
    --spec) spec="$2" ;;
    --env-file) env_file="$2" ;;
    --expect-db) expect_db="$2" ;;
    --out) out="$2" ;;
    --weight) weight="$2" ;;
    *) usage ;;
  esac
  shift 2
done
for required in "$host" "$repo_dir" "$dir" "$sub" "$gate" "$spec" "$env_file" "$expect_db" "$out"; do
  [ -n "$required" ] || usage
done
# Bun loads the env file in place; a caught URL error must never echo its input.
guard=$(cat <<'JS'
try {
  const url = new URL(process.env.DATABASE_URL);
  if (!['postgres:', 'postgresql:'].includes(url.protocol)) throw new Error();
  const database = decodeURIComponent(url.pathname.slice(1));
  if (!url.hostname || !database || /[\x00-\x1f\x7f]/.test(url.hostname + database)) throw new Error();
  console.log(`host=${url.hostname} db=${database}`);
  if (database !== process.argv[1]) {
    console.error('remote-shot: database does not match --expect-db');
    process.exit(64);
  }
} catch {
  console.error('remote-shot: missing or invalid DATABASE_URL');
  process.exit(64);
}
JS
)
printf -v check_cmd '%q ' bun --env-file "$env_file" -e "$guard" -- "$expect_db"
printf -v test_cmd '%q ' bun --env-file "$env_file" x playwright test "$spec"
exec bash "$(dirname "${BASH_SOURCE[0]}")/remote-heavy.sh" \
  --host "$host" --repo-dir "$repo_dir" --dir "$dir" --sub "$sub" \
  --gate "$gate" --weight "$weight" --fetch "$sub/test-results/**/*.png" --into "$out" \
  -- bash -c "$check_cmd && $test_cmd"
