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

brew install coreutils curl git

brew install asdf
#git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0

asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

asdf list all nodejs | wc -l

asdf install nodejs 22.14.0
#asdf global nodejs 22.14.0
#asdf shell nodejs 22.14.0
asdf set -u nodejs 22.14.0


asdf plugin update --all


# install bun
curl -fsSL https://bun.sh/install | bash
