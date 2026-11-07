#!/usr/bin/env bash
# Install or repair the GitHub runner of a macOS host so it can run Review:
#   setup-review-runner.sh <owner/repo> <runner name> [runner dir]
# The runner dir defaults to ~/actions-runner-<repo name>; pass the old dir to repair an existing runner.
# A runner service gets SessionCreate, which starts a new security session where the login keychain is
# locked: claude then says "Not logged in" although it works in a terminal. This script removes it.
set -euo pipefail
repo=$1 name=$2
dir=${3:-$HOME/actions-runner-${repo#*/}}
label=actions.runner.${repo/\//-}.$name
plist=$HOME/Library/LaunchAgents/$label.plist
domain=gui/$(id -u)
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.node_modules/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$dir"; cd "$dir"
if [ ! -f .runner ]; then
  case "$(uname -m)" in arm64) arch=arm64 ;; *) arch=x64 ;; esac
  version=$(gh api repos/actions/runner/releases/latest --jq .tag_name)
  curl -fsSL "https://github.com/actions/runner/releases/download/$version/actions-runner-osx-$arch-${version#v}.tar.gz" | tar -xz
  token=$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)
  ./config.sh --unattended --url "https://github.com/$repo" --token "$token" --name "$name" --labels review --replace
fi
[ -f "$plist" ] || ./svc.sh install
/usr/libexec/PlistBuddy -c 'Delete :SessionCreate' "$plist" 2>/dev/null || true
printf '%s' "$PATH" > .path
launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist"
echo "setup-review-runner: $name running in $domain"
