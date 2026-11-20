#!/bin/bash

#no longer needed in high sierra
#sudo chown -R $(whoami):admin /usr/local

# shellcheck source=../../script/lib/app-path.sh disable=SC1091
. "$HOME/dotfiles/script/lib/app-path.sh"
orca_app=$(app_path Orca.app)
orca_ver() { defaults read "$orca_app/Contents/Info" CFBundleShortVersionString 2>/dev/null; }
orca_before=$(orca_ver)

brew update
brew upgrade --greedy
#brew upgrade --cask --greedy

# A cask whose app sits in another folder than brew recorded (an old HOMEBREW_CASK_OPTS
# appdir, or an app moved by hand) fails to upgrade with "App source is
# not there". Reinstall each one over the app where it really is.
for cask in $(brew outdated --cask --greedy --quiet); do
  app=$(brew info --cask --json=v2 "$cask" | jq -r '[.casks[0].artifacts[] | select(.app) | .app[0] | strings][0] // empty')
  [ -n "$app" ] || continue
  for dir in $APP_DIRS /Applications/Utilities; do
    if [ -d "$dir/$app" ]; then
      brew install --cask --force --appdir="$dir" "$cask"
      break
    fi
  done
done

mas upgrade

brew cleanup
brew doctor

rm -rf ~/Library/Caches/Homebrew/downloads/*
softwareupdate --all --install --force

# Orca is always open, and an upgraded Orca.app keeps running the old version until
# it restarts. Restart it when this run changed its version. The restart runs
# detached because quitting Orca ends a shell running inside it.
orca_exe="$orca_app/Contents/MacOS/Orca"
if [ "$(orca_ver)" != "$orca_before" ] && pgrep -f "^$orca_exe\$" >/dev/null; then
  echo "Restarting Orca to load $(orca_ver)"
  nohup bash -c "osascript -e 'quit app \"Orca\"'
    n=0; while pgrep -f '^$orca_exe\$' >/dev/null && [ \$n -lt 30 ]; do sleep 1; n=\$((n + 1)); done
    pkill -f '^$orca_exe\$'; sleep 2; env -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT open -g '$orca_app'" >/dev/null 2>&1 &
fi
