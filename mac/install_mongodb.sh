#!/bin/bash

# this is cloud setup
# brew install mongodb-atlas
# atlas setup

# https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-os-x/
brew install --cask --appdir="/Applications/_dev" mongodb-compass

brew tap mongodb/brew
brew update

brew install mongodb-community@7.0

brew services start mongodb-community

ps aux | grep -v grep | grep mongod
