#!/bin/sh

#no longer needed in high sierra
#sudo chown -R $(whoami):admin /usr/local

brew update
brew upgrade
brew upgrade --cask --greedy

#brew update && brew upgrade
#brew cleanup
mas upgrade

brew cleanup
brew doctor

rm -rf ~/Library/Caches/Homebrew/downloads/*
softwareupdate --all --install --force
