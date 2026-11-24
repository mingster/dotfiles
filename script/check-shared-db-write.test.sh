#!/usr/bin/env bash
# Tests for script/check-shared-db-write.py: schema writes to shared app_dev* databases are refused (#1680).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
printf 'shared: ^app_dev(_s[0-9]+)?$\nverifier: app_verifier_\n' >"$tmp/pattern"
export SHARED_DB_PATTERN_FILE="$tmp/pattern"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
# Two checkouts: merged (HEAD equals origin/main) and unmerged (one commit ahead of origin/main).
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/merged" 2>/dev/null
git -C "$tmp/merged" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$tmp/merged" push -q origin HEAD:main 2>/dev/null
git -C "$tmp/merged" fetch -q origin
git clone -q "$tmp/origin.git" "$tmp/unmerged" 2>/dev/null
git -C "$tmp/unmerged" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead
cwd=$tmp/merged
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# run <role|-> <env DATABASE_URL|-> <command>: feeds a PreToolUse payload; sets out and rc.
run() {
  local role=$1 dburl=$2 cmd=$3 transcript=$tmp/t.jsonl
  if [ "$role" = - ]; then text="hello"
  elif [ -n "${ORCA_PREAMBLE:-}" ]; then text="You are working inside Orca, a multi-agent IDE.
=== TASK ===
Worker role: $role
do work"
  else text="Worker role: $role
do work"; fi
  jq -nc --arg t "$text" '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' >"$transcript"
  payload=$(jq -nc --arg c "$cmd" --arg t "$transcript" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$t,cwd:$d}')
  if [ "$dburl" = - ]; then
    out=$(printf '%s' "$payload" | env -u DATABASE_URL -u DIRECT_URL python3 "$here/check-shared-db-write.py" 2>"$tmp/err"); rc=$?
  else
    out=$(printf '%s' "$payload" | env DATABASE_URL="$dburl" python3 "$here/check-shared-db-write.py" 2>"$tmp/err"); rc=$?
  fi
}
blocked() { # name role dburl command
  run "$2" "$3" "$4"
  if [ "$rc" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null 2>&1 \
     && grep -q 'app_verifier_' <<<"$out"; then ok "blocks $1"; else bad "blocks $1" "rc=$rc out=$out"; fi
}
allowed() {
  run "$2" "$3" "$4"
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "allows $1"; else bad "allows $1" "rc=$rc out=$out"; fi
}

blocked "psql CREATE on dev" builder - 'psql -d app_dev -c "CREATE TABLE x (id int)"'
blocked "psql ALTER on shard" fullstack-dev - 'psql postgres://u@h/app_dev_s1 -c "alter table t add c int"'
blocked "psql DROP on shard 12" - - 'psql -h h app_dev_s12 -c "DROP TABLE t"'
blocked "prisma db push on url" builder - 'DATABASE_URL=postgres://u@h:5432/app_dev_s1?schema=public npx prisma db push'
blocked "prisma db execute" builder - 'DATABASE_URL="postgresql://h/app_dev" bunx prisma db execute --file x.sql'
blocked "prisma migrate deploy" builder - 'DATABASE_URL=postgres://h/app_dev_s2 npx prisma migrate deploy'
blocked "prisma migrate dev from env DATABASE_URL" builder 'postgres://h/app_dev_s1' 'npx prisma migrate dev'
blocked "dbpush from env DATABASE_URL" builder 'postgres://h/app_dev' 'bun run dbpush'
blocked "dbpush with --url naming shard" builder - 'bun run dbpush --url postgres://h/app_dev_s3'
printf 'DROP TABLE t;' >"$tmp/x.sql"
blocked "psql DDL in a sql file" builder - "psql app_dev_s1 -f \"$tmp/x.sql\""

allowed "psql SELECT on dev" builder - 'psql -d app_dev -c "select 1"'
printf 'SELECT 1;' >"$tmp/select.sql"
allowed "psql SELECT from a sql file" builder - "psql app_dev_s1 -f \"$tmp/select.sql\""
allowed "verifier temp DB DDL" builder - 'psql -d app_verifier_ab12 -c "CREATE TABLE x (id int)"'
allowed "prisma db push on verifier URL" builder - 'DATABASE_URL=postgres://h/app_verifier_9z npx prisma db push'
allowed "verifier URL beats env dev URL" builder 'postgres://h/app_dev' 'DATABASE_URL=postgres://h/app_verifier_x npx prisma migrate deploy'
allowed "similar name app_dev_old" builder - 'psql -d app_dev_old -c "DROP TABLE t"'
allowed "unrelated prisma generate" builder 'postgres://h/app_dev' 'npx prisma generate'
allowed "migrate with no dev target" builder 'postgres://h/other_db' 'npx prisma migrate dev'
allowed "release-manager role" release-manager - 'DATABASE_URL=postgres://h/app_dev_s1 npx prisma migrate deploy'
rm_cmd='DATABASE_URL=postgres://h/app_dev_s1 npx prisma migrate deploy'
ORCA_PREAMBLE=1 allowed "release-manager role after the Orca preamble" release-manager - "$rm_cmd"
ORCA_PREAMBLE=1 blocked "builder role after the Orca preamble" builder - "$rm_cmd"
cwd=$tmp/unmerged
blocked "release-manager on an unmerged branch" release-manager - "$rm_cmd"
ORCA_PREAMBLE=1 blocked "release-manager on an unmerged branch after the preamble" release-manager - "$rm_cmd"
cwd=$tmp
blocked "release-manager outside a git checkout" release-manager - "$rm_cmd"
cwd=$tmp/merged
allowed "message body naming dbpush" builder 'postgres://h/app_dev' 'orca orchestration send --type status --subject "sync" --body "run dbpush then prisma migrate deploy on app_dev_s1"'
allowed "message body with --body=" builder 'postgres://h/app_dev' "orca orchestration send --body='psql app_dev -c DROP TABLE t'"
blocked "dbpush after a message in one command" builder 'postgres://h/app_dev' 'orca orchestration send --body "hi" && bun run dbpush'
# Quoted heredoc bodies fed to a text sink are text (#1796); bodies fed to a shell or psql still count.
allowed "cat heredoc note naming dbpush and a shared db" builder - "cat > /tmp/m.md <<'EOF'
Never \`dbpush\` a schema from an unmerged branch to a shared app_dev_s1 database
EOF"
allowed "cat append heredoc with DDL text" builder - "cat >> /tmp/m.md <<\"EOF\"
psql app_dev -c 'DROP TABLE t'
EOF"
allowed "tee heredoc note" builder - "tee /tmp/m.md <<'EOF'
run bun run dbpush on app_dev
EOF"
allowed "git commit -F - heredoc" builder - "git commit -F - <<'EOF'
fix: dbpush app_dev_s1 note
EOF"
allowed "gh --body-file - heredoc" builder - "gh issue create --body-file - <<'EOF'
psql app_dev -c 'ALTER TABLE x ADD y int'
EOF"
blocked "psql heredoc DDL on shared db" builder - "psql postgres://h/app_dev_s1 <<'SQL'
ALTER TABLE x ADD y int;
SQL"
blocked "psql heredoc DDL on shared db from env" builder 'postgres://h/app_dev' "psql \"\$DATABASE_URL\" <<'SQL'
ALTER TABLE x ADD y int;
SQL"
blocked "ssh prisma db push on shared db" builder 'postgres://h/app_dev_s1' "ssh host 'cd app && bunx prisma db push'"
blocked "bash heredoc running dbpush" builder 'postgres://h/app_dev' "bash <<'EOF'
bun run dbpush
EOF"
blocked "unquoted cat heredoc is expanded by the shell" builder 'postgres://h/app_dev' "cat > /tmp/m.md <<EOF
\$(bun run dbpush)
EOF"
blocked "tee piped to a shell keeps the body" builder 'postgres://h/app_dev' "tee /tmp/m.sh <<'EOF' | bash
bun run dbpush
EOF"
blocked "dbpush after a text heredoc" builder 'postgres://h/app_dev' "cat > /tmp/m.md <<'EOF'
note
EOF
bun run dbpush"
allowed "bootstrap-regression-shard.ts" builder - 'bun bin/bootstrap-regression-shard.ts --db app_dev_s1 && psql app_dev_s1 -c "CREATE TABLE t (i int)"'
allowed "non Bash tool" builder - 'ls'
payload='{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
out=$(printf '%s' "$payload" | python3 "$here/check-shared-db-write.py"); [ $? -eq 0 ] && [ -z "$out" ] && ok "ignores non Bash payload" || bad "non Bash payload" "$out"
out=$(printf 'not json' | python3 "$here/check-shared-db-write.py"); [ $? -eq 0 ] && [ -z "$out" ] && ok "bad input exits 0" || bad "bad input" "$out"

# CLI mode: --command prints a refusal and exits 1, or exits 0.
python3 "$here/check-shared-db-write.py" --command 'npx prisma db push app_dev_s1' >"$tmp/o" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q app_verifier_ "$tmp/o" && ok "--command refuses with exit 1" || bad "--command refuse" "rc=$rc"
python3 "$here/check-shared-db-write.py" --command 'echo hi' >/dev/null 2>&1 && ok "--command allows with exit 0" || bad "--command allow" "rc=$?"
python3 "$here/check-shared-db-write.py" --help >"$tmp/o" 2>&1 && grep -q Usage "$tmp/o" && ok "--help exits 0" || bad "--help" "rc=$?"

SHARED_DB_PATTERN_FILE="$tmp/missing" python3 "$here/check-shared-db-write.py" --command 'prisma db push app_dev' >/dev/null 2>"$tmp/e"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "nothing checked" "$tmp/e"; } && ok "no pattern file checks nothing and says so" || bad "no pattern file" "rc=$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
