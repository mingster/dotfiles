#!/bin/sh

#no longer needed in high sierra
#sudo chown -R $(whoami):admin /usr/local

brew update && brew upgrade
brew cleanup
mas upgrade
brew doctor

softwareupdate --all --install --force
