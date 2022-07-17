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

# Install data stores
#brew install mysql
#brew services start mysql
#brew services stop mysql


#https://github.com/laradock/laradock/issues/93
brew uninstall mariadb
rm -rf /usr/local/etc/my.cnf; rm -rf /usr/local/etc/my.cnf.d; rm -rf /usr/local/etc/my.cnf.default

#remove db --beware
# rm -rf /usr/local/var/mysql/
brew install mariadb

#  https://mariadb.com/resources/blog/installing-mariadb-10-1-16-on-mac-os-x-with-homebrew/
## RUN mysql_install_db ##
#brew services start mariadb
#brew services stop mariadb


#brew install postgresql
#brew install mongo
#brew install redis
#brew install elasticsearch

# Install mysql workbench
# Install Cask
#brew install caskroom/cask/brew-cask
#brew install --cask --appdir="/Applications/_dev" mysqlworkbench
brew install --cask --appdir="/Applications/_dev" sequel-pro

# Remove outdated versions from the cellar.
brew cleanup
