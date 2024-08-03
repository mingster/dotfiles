#!/bin/sh

#no longer needed in high sierra
#sudo chown -R $(whoami):admin /usr/local

brew update && brew upgrade && brew cleanup

#brew update && brew upgrade

brew upgrade --cask
#brew cleanup
mas upgrade
brew doctor

rm -rf ~/Library/Caches/Homebrew/downloads/*
softwareupdate --all --install --force
