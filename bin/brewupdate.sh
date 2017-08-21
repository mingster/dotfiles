#!/bin/sh
sudo chown -R $(whoami):admin /usr/local
brew update && brew upgrade
brew cleanup
mas upgrade
brew doctor
