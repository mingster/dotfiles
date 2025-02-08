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

# we will use asdf / asdf-direnv and .envrc to manage py dev env
# https://github.com/asdf-community/asdf-direnv#motivation-or-shims-de-motivation
# https://yeray.dev/python/direnv-asdf-python-virtualenv

# uninstall python from brew
brew list | grep -iE 'python'
for pkg in $(brew list | grep -iE 'node'); do brew uninstall $pkg --ignore-dependencies; done

# use asdf instead

# https://asdf-vm.com/manage/configuration.html
# https://rednafi.com/python/install_python_with_asdf/
# https://github.com/asdf-community/asdf-python
asdf plugin add python

asdf install python 3.11.1
#asdf global python 3.11.1
asdf set -u python 3.11.1

asdf plugin add direnv

asdf direnv install.bash
asdf direnv local.bash
asdf direnv setup.bash
asdf direnv shell.bash

# If you use pip to install a module like ipython that has binaries. You will need to run asdf reshim python
# for the binary to be in your path.


python -V

# use .envrc in py project
#
# Create a .envrc  file, should look like something this:
# use asdf
# layout python python3.10
