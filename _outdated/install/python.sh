#!/usr/bin/env bash

# @https://hackercodex.com/guide/python-development-environment-on-mac-osx/
# @https://asdf-vm.com/guide/getting-started.html

# Install asdf Dependencies
brew install coreutils curl git
# Install asdf
brew install asdf openssl readline sqlite3 xz zlib

# Install python
asdf plugin add python
asdf install python latest

##
asdf global python latest   #or specify version such as 3.12.1

# activate asdf
# @https://mac.install.guide/ruby/5.html
echo -e "\n. $(brew --prefix asdf)/libexec/asdf.sh" >> ~/.zshrc

# Confirm the Python version matches the latest version we just installed:
python --version

#pip
python -m pip install --upgrade pip setuptools direnv

#Virtualenv
python -m pip install virtualenv
asdf reshim python


brew install direnv
