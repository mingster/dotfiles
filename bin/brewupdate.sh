#!/bin/sh
sudo chown -R $(whoami):admin /usr/local
brew update && brew upgrade
brew cask cleanup && brew cleanup
mas upgrade
