#!/bin/bash

#no longer needed in high sierra
#sudo chown -R $(whoami):admin /usr/local

brew update
brew upgrade --greedy
#brew upgrade --cask --greedy

mas upgrade

brew cleanup
brew doctor

rm -rf ~/Library/Caches/Homebrew/downloads/*
softwareupdate --all --install --force
