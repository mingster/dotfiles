#!/usr/bin/env bash
# env-peek.py: masks secrets, shows short plain values, and fingerprints non dotenv files. Fake values only.
here=$(cd "$(dirname "$0")/../.." && pwd)
peek="$here/templates/agent-team/.claude/bin/env-peek.py"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
fp() { printf %s "$1" | shasum -a 256 | cut -c1-8; }
# has <output> <regex>; lacks <output> <fixed string>. Neither prints the output.
has() { grep -qE -- "$2" <<<"$1" && echo 0 || echo 1; }
lacks() { grep -qF -- "$2" <<<"$1" && echo 1 || echo 0; }

S_PLAIN=fake-not-real-1; S_TOKEN=fake-token-value; S_URLPW=fakeurlpw; S_URLUSER=fakeurluser
S_KVPW=fakekvpw; S_KVUSER=fakekvuser; S_QUOTED="fake quoted secret"
cat >"$tmp/.env" <<ENV
# a comment
PLAIN=short
API_TOKEN=$S_TOKEN
DATABASE_URL=postgres://$S_URLUSER:$S_URLPW@db.example.com:5432/app
MSSQL=sqlserver://host:1433;database=app_test;user=$S_KVUSER;password=$S_KVPW
QUOTED_PASSWORD="$S_QUOTED"
QUOTED_PLAIN='two words'
EMPTY=
ENV

out=$(python3 "$peek" "$tmp/.env" PLAIN API_TOKEN DATABASE_URL MSSQL QUOTED_PASSWORD QUOTED_PLAIN EMPTY ABSENT)
line() { grep "^$1 = " <<<"$out"; }

check "short plain value shown" "$([ "$(line PLAIN)" = "PLAIN = short" ] && echo 0 || echo 1)"
check "secret named key masked with length and fingerprint" "$([ "$(line API_TOKEN)" = "API_TOKEN = <set, ${#S_TOKEN} chars, fp $(fp "$S_TOKEN")>" ] && echo 0 || echo 1)"
check "secret value not printed" "$(lacks "$out" "$S_TOKEN")"
url=$(line DATABASE_URL)
check "URL credentials masked" "$(has "$url" 'postgres://\*\*\*:\*\*\*@db\.example\.com:5432/app')"
check "URL credentials not printed" "$([ "$(lacks "$url" "$S_URLUSER")" = 0 ] && lacks "$url" "$S_URLPW" || echo 1)"
check "URL line carries a fingerprint" "$(has "$url" '\(fp [0-9a-f]{8}\)$')"
kv=$(line MSSQL)
check ";password= masked" "$(has "$kv" ';password=\*\*\*')"
check "user= masked" "$(has "$kv" ';user=\*\*\*')"
check "key value credentials not printed" "$([ "$(lacks "$kv" "$S_KVPW")" = 0 ] && lacks "$kv" "$S_KVUSER" || echo 1)"
check "key value keeps non secret parts" "$(has "$kv" 'sqlserver://host:1433;database=app_test')"
check "quoted secret masked" "$([ "$(line QUOTED_PASSWORD)" = "QUOTED_PASSWORD = <set, ${#S_QUOTED} chars, fp $(fp "$S_QUOTED")>" ] && echo 0 || echo 1)"
check "quoted plain value loses its quotes" "$([ "$(line QUOTED_PLAIN)" = "QUOTED_PLAIN = two words" ] && echo 0 || echo 1)"
check "empty key" "$([ "$(line EMPTY)" = "EMPTY = <empty>" ] && echo 0 || echo 1)"
check "missing key" "$([ "$(line ABSENT)" = "ABSENT = <missing>" ] && echo 0 || echo 1)"

all=$(python3 "$peek" "$tmp/.env")
check "no key args lists every key sorted" "$([ "$(cut -d' ' -f1 <<<"$all" | tr '\n' ' ')" = "API_TOKEN DATABASE_URL EMPTY MSSQL PLAIN QUOTED_PASSWORD QUOTED_PLAIN " ] && echo 0 || echo 1)"
long=$(printf 'x%.0s' $(seq 61))
printf 'LONG=%s\n' "$long" >"$tmp/long.env"
check "plain key with a value over 60 chars is masked" "$([ "$(python3 "$peek" "$tmp/long.env" LONG)" = "LONG = <set, 61 chars, fp $(fp "$long")>" ] && echo 0 || echo 1)"

printf 'not a dotenv file, just text\n' >"$tmp/note.txt"
size=$(wc -c <"$tmp/note.txt" | tr -d " ")
nd=$(python3 "$peek" "$tmp/note.txt")
check "non dotenv file prints a fingerprint" "$([ "$nd" = "$tmp/note.txt: not a dotenv file; $size bytes, fp $(shasum -a 256 <"$tmp/note.txt" | cut -c1-8)" ] && echo 0 || echo 1)"
check "non dotenv file content not printed" "$(lacks "$nd" "just text")"

python3 "$peek" "$tmp/nope" >/dev/null 2>&1; rc=$?
check "missing file exits 1" "$([ "$rc" = 1 ] && echo 0 || echo 1)"

echo "env-peek: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
