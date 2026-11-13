#!/usr/bin/env bash
# shellcheck disable=SC2209
# Prints "<tool> ok <version>", "<tool> missing" or "<tool> unreadable" for each fleet tool on this host.
# fleet-toolchain-check.sh sends this file over ssh; session-sync.sh runs it locally.
[ -n "${ZSH_VERSION:-}" ] && emulate -L sh
export PATH="${FLEET_TOOLCHAIN_PATH:-$HOME/.local/bin:$HOME/.bun/bin:${ASDF_DATA_DIR:-$HOME/.asdf}/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH}"
stale="$HOME/.orca/cli/bin"
orca_bin=""
list="${FLEET_ORCA_APP_BIN:-${WRAP_UP_ORCA_APP_BIN:-/Applications/_dev/Orca.app/Contents/Resources/bin}}:$PATH:$HOME/.local/bin"
old_ifs=$IFS
IFS=:
for dir in $list; do
  if [ "$dir" != "$stale" ] && [ -x "$dir/orca" ]; then
    orca_bin="$dir/orca"
    break
  fi
done
IFS=$old_ifs
[ -z "$orca_bin" ] && [ -x "$stale/orca" ] && orca_bin="$stale/orca"

ver_token() {
  awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^v?[0-9]+\.[0-9]+/) {
        sub(/^v/, "", $i)
        print $i
        exit
      }
    }
  }'
}

for t in git gh jq python3 shellcheck bun node orca claude agent agy; do
  case $t in
    orca)
      if [ -z "$orca_bin" ]; then
        echo "orca missing"
      else
        v=$("$orca_bin" --version 2>/dev/null | head -1 | ver_token)
        [ -n "$v" ] && echo "orca ok $v" || echo "orca unreadable"
      fi
      ;;
    agent)
      bin=""
      if command -v agent >/dev/null 2>&1; then bin=agent
      elif command -v cursor-agent >/dev/null 2>&1; then bin=cursor-agent
      fi
      if [ -z "$bin" ]; then
        echo "agent missing"
      else
        v=$(AGENT_CLI_CREDENTIAL_STORE=file "$bin" --version 2>/dev/null | head -1 | ver_token)
        [ -n "$v" ] && echo "agent ok $v" || echo "agent unreadable"
      fi
      ;;
    jq)
      if ! command -v jq >/dev/null 2>&1; then
        echo "jq missing"
      else
        raw=$(jq --version 2>/dev/null | head -1)
        v=$(printf '%s\n' "$raw" | sed -E 's/^jq-//; s/^jq[[:space:]]+(version[[:space:]]+)?//; s/^v//; s/^[[:space:]]+|[[:space:]]+$//g')
        if printf '%s\n' "$v" | grep -qE '^[0-9]+\.[0-9]+'; then
          echo "jq ok $v"
        else
          echo "jq unreadable"
        fi
      fi
      ;;
    *)
      if ! command -v "$t" >/dev/null 2>&1; then
        echo "$t missing"
      else
        v=$("$t" --version 2>/dev/null | ver_token)
        [ -n "$v" ] && echo "$t ok $v" || echo "$t unreadable"
      fi
      ;;
  esac
done
