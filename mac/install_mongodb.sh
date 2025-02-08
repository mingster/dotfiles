#!/usr/bin/env bash


# this is cloud setup
# brew install mongodb-atlas
# atlas setup

# https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-os-x/
brew install --cask --appdir="/Applications/_dev" mongodb-compass

brew tap mongodb/brew
brew update

brew install mongodb-community@8.0

#To start mongodb/brew/mongodb-community now and restart at login:
#  brew services start mongodb/brew/mongodb-community

## add relication to /usr/local/etc/mongod.conf
#replication:
#    replSetName: rs0

architecture=$(uname -m)
if [ "$architecture" == "arm64" ]; then
  echo "replication:" >> /opt/homebrew/etc/mongod.conf
  echo "  replSetName: rs0" >> /opt/homebrew/etc/mongod.conf
elif [ "$architecture" == "x86_64" ]; then
  echo "replication:" >> /usr/local/etc/mongod.conf
  echo "  replSetName: rs0" >> /usr/local/etc/mongod.conf
else
    echo "Unknown architecture: $architecture"
fi

brew services start mongodb/brew/mongodb-community

# https://www.mongodb.com/docs/manual/tutorial/deploy-replica-set/
# in mongosh, execute rs.initiate()
# in mongosh, execute rs.config() to review

ps aux | grep -v grep | grep mongod
mongosh
mongod --version
