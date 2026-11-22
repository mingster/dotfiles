#!/usr/bin/env bash


# this is cloud setup
# brew install mongodb-atlas
# atlas setup

# https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-os-x/
brew install --cask mongodb-compass

brew tap mongodb/brew
brew update

brew install mongodb-community@8.0

#To start mongodb/brew/mongodb-community now and restart at login:
#  brew services start mongodb/brew/mongodb-community

## add relication to /usr/local/etc/mongod.conf
#replication:
#    replSetName: rs0

if [ -z "${MONGOD_CONF:-}" ]; then
  architecture=$(uname -m)
  if [ "$architecture" == "arm64" ]; then
    MONGOD_CONF=/opt/homebrew/etc/mongod.conf
  elif [ "$architecture" == "x86_64" ]; then
    MONGOD_CONF=/usr/local/etc/mongod.conf
  else
    echo "Unknown architecture: $architecture"
  fi
fi

# Append once: a second replication: key makes mongod refuse to start.
if [ -n "${MONGOD_CONF:-}" ] && ! grep -Eq '^[[:space:]]*replSetName:' "$MONGOD_CONF" 2>/dev/null; then
  echo "replication:" >> "$MONGOD_CONF"
  echo "  replSetName: rs0" >> "$MONGOD_CONF"
fi

brew services start mongodb/brew/mongodb-community

# https://www.mongodb.com/docs/manual/tutorial/deploy-replica-set/
# in mongosh, execute rs.initiate()
# in mongosh, execute rs.config() to review

ps aux | grep -v grep | grep mongod
mongosh
mongod --version
