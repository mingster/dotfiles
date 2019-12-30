#!/bin/sh

#no longer needed in high sierra
#sudo chown -R $(whoami):admin /usr/local

brew update && brew upgrade

brew cask upgrade
brew cleanup
mas upgrade
brew doctor
