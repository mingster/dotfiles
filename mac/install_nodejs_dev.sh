#!/usr/bin/env bash


# Ask for the administrator password upfront.
sudo -v

# Keep-alive: update existing `sudo` time stamp until the script has finished.
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Check for Homebrew,
# Install if we don't have it
if test ! $(which brew); then
  echo "Installing homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make sure we’re using the latest Homebrew.
brew update

brew list | grep -iE 'node'
for pkg in $(brew list | grep -iE 'node'); do brew --ignore-dependencies uninstall $pkg; done

asdf plugin update --all

# https://blog.logrocket.com/manage-node-js-versions-using-asdf/
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

#asdf nodejs update-nodebuild.bash

asdf list all nodejs

#asdf nodejs resolve lts --latest-available

asdf install nodejs 20.18.0
#asdf global nodejs 20.18.0
#asdf shell nodejs 20.18.0
asdf set -u nodejs 20.18.0


npm install -g npm@latest

corepack enable

#npm install -g yarn
#corepack prepare yarn@latest --activate

asdf reshim nodejs

# install bun
curl -fsSL https://bun.sh/install | bash
