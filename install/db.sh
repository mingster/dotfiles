#!/usr/bin/env bash

# Install command-line tools using Homebrew.

# Ask for the administrator password upfront.
sudo -v

# Keep-alive: update existing `sudo` time stamp until the script has finished.
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Check for Homebrew,
# Install if we don't have it
if test ! $(which brew); then
  echo "Installing homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make sure we’re using the latest Homebrew.
brew update


##### mariadb #####
#https://github.com/laradock/laradock/issues/93
#brew uninstall mariadb
#rm -rf /usr/local/etc/my.cnf; rm -rf /usr/local/etc/my.cnf.d; rm -rf /usr/local/etc/my.cnf.default

#remove db --beware
# rm -rf /usr/local/var/mysql/
#brew install mariadb

#  https://mariadb.com/resources/blog/installing-mariadb-10-1-16-on-mac-os-x-with-homebrew/
## RUN mysql_install_db ##
#brew services start mariadb
#brew services stop mariadb


##### mysql #####
#brew install mysql
#brew services start mysql
#brew services stop mysql

brew install mysql-client

##### postgre #####
# https://www.codementor.io/@engineerapart/getting-started-with-postgresql-on-mac-osx-are8jcopb
# brew install postgresql

## service ##

# To start postgresql@14 now and restart at login:
#   brew services start postgresql@14
#Or, if you don't want/need a background service you can just run:
#  /usr/local/opt/postgresql@14/bin/postgres -D /usr/local/var/postgresql@14

# brew services start postgresql
# or "brew services run postgresql" to have it not restart at boot time

## connect / admin gui ##
# psql postgres
# brew install --cask --appdir="/Applications/_dev" pgadmin4
# brew install --cask --appdir="/Applications/_dev" dbeaver-community

#brew install mongo

##### redis #####
brew install redis

#To start redis now and restart at login:
#brew services start redis

#start redis from console
#/usr/local/opt/redis/bin/redis-server /usr/local/etc/redis.conf






#brew install elasticsearch

# Install mysql workbench
# Install Cask
#brew install caskroom/cask/brew-cask
#brew install --cask --appdir="/Applications/_dev" mysqlworkbench
brew install --cask --appdir="/Applications/_dev" sequel-pro

# Remove outdated versions from the cellar.
brew cleanup
