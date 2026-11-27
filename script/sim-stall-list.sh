#!/usr/bin/env bash
# List this host's xcodebuild and build-and-test.sh processes for fleet-watch's stall check (#1970). Read only.
# One record each: SIM|pid|%CPU of the process and its children|age seconds|cwd|command|EOR, then SIM-END.
# Pipes, not tabs: a remote host is read from a terminal screen, which expands tabs and may wrap a record.
# A matched process with a matched child (build-and-test.sh around xcodebuild) is left out.
set -euo pipefail
ps -axww -o pid=,ppid=,pcpu=,etime=,command= | awk '
  function seconds(t,   d, n, p, i, s) {
    d = 0
    if (split(t, p, "-") == 2) { d = p[1]; t = p[2] }
    n = split(t, p, ":")
    s = 0
    for (i = 1; i <= n; i++) s = s * 60 + p[i]
    return d * 86400 + s
  }
  {
    pid = $1; parent[pid] = $2; cpu[pid] = $3; age[pid] = seconds($4)
    line = $0
    sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", line)
    cmd[pid] = line
    if (line ~ /^([^ ]*\/)?xcodebuild( |$)/ || line ~ /^(([^ ]*\/)?(ba|z)?sh +(-[^ ]+ +)*)?([^ ]*\/)?build-and-test\.sh( |$)/) hit[pid] = 1
  }
  END {
    for (pid in cpu) {
      seen = 0
      for (p = pid; (p in parent) && seen < 64; p = parent[p]) {
        total[p] += cpu[pid]
        if (p != pid && (pid in hit) && (p in hit)) wrapper[p] = 1
        seen++
      }
    }
    for (pid in hit) if (!(pid in wrapper)) printf "%d\t%.1f\t%d\t%s\n", pid, total[pid], age[pid], substr(cmd[pid], 1, 160)
  }' | sort -n | while IFS=$'\t' read -r pid cpu age command; do
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1) || cwd=
  printf 'SIM|%s|%s|%s|%s|%s|EOR\n' "$pid" "$cpu" "$age" "$cwd" "$command"
done
echo SIM-END
