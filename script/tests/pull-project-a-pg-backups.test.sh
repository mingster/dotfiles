#!/usr/bin/env bash
# Tests for arch/bin/pull-project-a-pg-backups.sh (stubbed rsync/find/stat on macOS).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
script="$root/arch/bin/pull-project-a-pg-backups.sh"
conf_name=pull-project-a-pg-backups.local.conf

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$tmp/bin" "$HOME"

pass=0
fail=0

# GNU find/stat shims for macOS test hosts.
cat > "$tmp/bin/rsync" <<'SH'
#!/usr/bin/env bash
dest="${!#}"
dest="${dest%/}"
mkdir -p "$dest/$(date +%Y%m%d)"
exit 0
SH
cat > "$tmp/bin/find" <<'SH'
#!/usr/bin/env bash
if [ "$2" = "-mindepth" ] && [ "${8:-}" = "-printf" ]; then
  root=$1
  newest=$(ls -1 "$root" 2>/dev/null | sort -r | head -1)
  [ -n "$newest" ] || exit 0
  printf '9 %s/%s\n' "$root" "$newest"
  exit 0
fi
if [ "$2" = "-mindepth" ] && [ "$6" = "-type" ] && [ "$7" = "d" ] && [ -z "${8:-}" ]; then
  root=$1
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    basename "$d"
  done
  exit 0
fi
exec /usr/bin/find "$@"
SH
cat > "$tmp/bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%Y" ]; then
  date +%s
  exit 0
fi
exec /usr/bin/stat "$@"
SH
chmod +x "$tmp/bin/rsync" "$tmp/bin/find" "$tmp/bin/stat"
export PATH="$tmp/bin:$PATH"

default_dest="$HOME/backup/project-a-pg"

set +e
missing_out=$(bash "$script" 2>&1)
missing_ec=$?
set -e
if [ "$missing_ec" -ne 0 ] \
  && echo "$missing_out" | grep -q "missing pull backup config:" \
  && echo "$missing_out" | grep -q "$conf_name" \
  && [ ! -d "$default_dest" ]; then
  pass=$((pass + 1))
  echo "ok   missing config fails before dest is created"
else
  fail=$((fail + 1))
  echo "FAIL missing config (exit $missing_ec)"
  echo "$missing_out" | head -5
fi

real_bin="$tmp/real-bin"
link_bin="$tmp/link-bin"
mkdir -p "$real_bin" "$link_bin"
cp "$script" "$real_bin/pull-project-a-pg-backups.sh"
dest_from_conf="$tmp/pull-dest-via-real-conf"
cat > "$real_bin/$conf_name" <<EOF
PULL_PG_DEST="$dest_from_conf"
PULL_PG_SRC="fixture@example.invalid:/backup/"
EOF
ln -s "$real_bin/pull-project-a-pg-backups.sh" "$link_bin/pull-project-a-pg-backups.sh"

set +e
symlink_out=$(bash "$link_bin/pull-project-a-pg-backups.sh" 2>&1)
symlink_ec=$?
set -e
if [ "$symlink_ec" -eq 0 ] && [ -d "$dest_from_conf" ]; then
  pass=$((pass + 1))
  echo "ok   symlink invoke loads conf beside real script"
else
  fail=$((fail + 1))
  echo "FAIL symlink conf resolution (exit $symlink_ec)"
  echo "$symlink_out" | head -5
fi

override_conf="$tmp/override.conf"
dest_override="$tmp/pull-dest-override"
cat > "$override_conf" <<EOF
PULL_PG_DEST="$dest_override"
PULL_PG_SRC="fixture@example.invalid:/backup/"
EOF
export PULL_PG_BACKUP_CONF="$override_conf"
set +e
override_out=$(bash "$real_bin/pull-project-a-pg-backups.sh" 2>&1)
override_ec=$?
set -e
unset PULL_PG_BACKUP_CONF
if [ "$override_ec" -eq 0 ] && [ -d "$dest_override" ]; then
  pass=$((pass + 1))
  echo "ok   PULL_PG_BACKUP_CONF overrides default conf path"
else
  fail=$((fail + 1))
  echo "FAIL PULL_PG_BACKUP_CONF override (exit $override_ec)"
  echo "$override_out" | head -5
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
