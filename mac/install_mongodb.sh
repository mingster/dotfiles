#!/bin/bash

# this is cloud setup
# brew install mongodb-atlas
# atlas setup

# https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-os-x/
brew install --cask --appdir="/Applications/_dev" mongodb-compass

brew tap mongodb/brew
brew update

brew install mongodb-community@7.0


## add relication to /usr/local/etc/mongod.conf
#replication:
#    replSetName: rs0

echo "replication:" >> /usr/local/etc/mongod.conf
echo "    replSetName: rs0" >> /usr/local/etc/mongod.conf

brew services start mongodb-community


# https://www.mongodb.com/docs/manual/tutorial/deploy-replica-set/
# in mongosh, execute rs.initiate()
# in mongosh, execute rs.config() to review

ps aux | grep -v grep | grep mongod
