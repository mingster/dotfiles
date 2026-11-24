#!/usr/bin/env bash
# Tests for templates/agent-team/.claude/bin/state-of-play.sh with gh and git stubbed or absent (#1502).
set -uo pipefail
# shellcheck source=script/tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
root=$(cd "$(dirname "$0")/../.." && pwd)
sop="$root/templates/agent-team/.claude/bin/state-of-play.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

realgit=$(command -v git)
bashbin=$(command -v bash)
mkdir -p "$tmp/home" "$tmp/bin" "$tmp/base"
# A base PATH with only what the script needs, so "gh missing" is real.
for t in bash git wc tr awk cat dirname basename date sed sleep kill mktemp rm; do ln -s "$(command -v $t)" "$tmp/base/$t"; done
printf '#!/usr/bin/env bash\n' >"$tmp/gh-body"
repo="$tmp/repo"; "$realgit" init -q -b main "$repo"
"$realgit" -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
mkgh() { # <issue-output> : a gh stub that prints the given text for `issue list` and one PR line for `pr list`
  printf '#!/bin/sh\ncase "$1 $2" in\n"issue list") echo "$*" >"%s/issue-args"; printf "%%b" %q ;;\n"pr list") echo "  #7 a pr [b] no review" ;;\nesac\n' "$tmp" "$1" >"$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
}
run() { # <path>
  HOME="$tmp/home" CLAUDE_PROJECT_DIR="$repo" PATH="$1" "$bashbin" "$sop" 2>&1
}

mkgh '  #9 down at midnight\n'
out=$(run "$tmp/bin:$tmp/base")
grep -q '^open P0 issues:' <<<"$out" && ok "heading names P0" || bad "heading" "$out"
grep -q '^  #9 down at midnight' <<<"$out" && ok "a P0 issue is listed" || bad "P0 present" "$out"
grep -q -- '--label P0' "$tmp/issue-args" && ! grep -q hotfix "$tmp/issue-args" && ok "gh is asked for the P0 label, not hotfix" || bad "label" "$(cat "$tmp/issue-args")"
grep -q 'hotfix' <<<"$out" && bad "hotfix" "output still says hotfix" || ok "no hotfix wording"

mkgh ''
out=$(run "$tmp/bin:$tmp/base")
grep -q '^open P0 issues:' <<<"$out" && ! grep -q '^  #[0-9]* .*midnight' <<<"$out" && grep -q '^open PRs:' <<<"$out" && ok "no P0 issues prints the heading and moves on" || bad "none" "$out"

out=$(run "$tmp/base")
grep -q 'open P0 issues' <<<"$out" && bad "gh missing" "printed P0 section without gh" || ok "gh missing skips the gh sections"
grep -q '^branch: main' <<<"$out" && ok "gh missing still prints the branch line" || bad "gh missing branch" "$out"

mkgh ''
out=$(run "$tmp/bin:$tmp/base")
grep -q 'branch: main | uncommitted files: 0 | no upstream' <<<"$out" && ok "no upstream is named" || bad "no upstream" "$out"

printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/gh"
out=$(run "$tmp/bin:$tmp/base")
grep -q '(gh unavailable)' <<<"$out" && ok "a failing gh prints (gh unavailable)" || bad "gh fails" "$out"

# A slow gh must not hold SessionStart: both calls run at once, each capped at 3 s (#1798).
printf '#!/bin/sh\nsleep 10\n' >"$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
start=$SECONDS
out=$(run "$tmp/bin:$tmp/base")
took=$((SECONDS - start))
[ "$took" -lt 4 ] && ok "two 10 s gh calls finish in ${took}s" || bad "slow gh" "took ${took}s"
[ "$(grep -c 'gh timed out' <<<"$out")" -eq 2 ] && ok "each slow gh part prints a timeout note" || bad "timeout note" "$out"
grep -q '^open PRs:' <<<"$out" && ok "slow gh still prints both headings" || bad "headings" "$out"

# With a fast gh the output is unchanged and the two calls overlap.
printf '#!/bin/sh\nsleep 2\ncase "$1 $2" in\n"issue list") echo "  #9 down at midnight" ;;\n"pr list") echo "  #7 a pr [b] no review" ;;\nesac\n' >"$tmp/bin/gh"
start=$SECONDS
out=$(run "$tmp/bin:$tmp/base")
took=$((SECONDS - start))
[ "$took" -lt 4 ] && ok "two 2 s gh calls overlap (${took}s)" || bad "overlap" "took ${took}s"
want=$(printf 'open P0 issues:\n  #9 down at midnight\nopen PRs:\n  #7 a pr [b] no review')
[ "$(tail -n 4 <<<"$out")" = "$want" ] && ok "fast gh output keeps the same headings and lines" || bad "fast output" "$out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
