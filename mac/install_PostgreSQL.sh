#!/usr/bin/env bash

#
# https://www.codementor.io/@engineerapart/getting-started-with-postgresql-on-mac-osx-are8jcopb
brew update
brew doctor

# remove old
brew list | grep -iE 'postgres'
brew list | grep postgres | xargs brew uninstall


brew install postgresql@18

architecture=$(uname -m)
if [ "$architecture" == "arm64" ]; then
  fish_add_path /opt/homebrew/opt/postgresql@18/bin
  pg_ctl -D /opt/homebrew/var/postgresql@18 start && brew services start postgresql@18
elif [ "$architecture" == "x86_64" ]; then
  fish_add_path /usr/local/opt/postgresql@18/bin
  pg_ctl -D /usr/local/var/postgresql@18 start && brew services start postgresql@18
else
    echo "Unknown architecture: $architecture"
fi

#postgresql@18 is keg-only, which means it was not symlinked into /usr/local,
#because this is an alternate version of another formula.

#If you need to have postgresql@18 first in your PATH, run:
#  fish_add_path /usr/local/opt/postgresql@18/bin
#
#For compilers to find postgresql@18 you may need to set:
#  set -gx LDFLAGS "-L/usr/local/opt/postgresql@18/lib"
#  set -gx CPPFLAGS "-I/usr/local/opt/postgresql@18/include"

#To start postgresql@18 now and restart at login:
#  brew services start postgresql@18
#Or, if you don't want/need a background service you can just run:
#  LC_ALL="C" /usr/local/opt/postgresql@18/bin/postgres -D /usr/local/var/postgresql@18
#
#brew services start postgresql@18

# TO REMOVE
# brew services stop postgresql@18
# brew uninstall postgresql@18
# rm -rf /usr/local/var/postgres
# rm -f ~/.psqlrc ~/.psql_history

# https://dev.to/uponthesky/postgresql-installing-postgresql-through-homebrew-on-macos-388h

#CREATE ROLE postgres WITH LOGIN PASSWORD 'quoted password'

createuser -s postgres

psql -h localhost -U postgres

## in the psql session, type \password postgres to set the password.

# CREATE NEW user
# in the psql sessesion, create new user as follow:
# CREATE ROLE PSTV_USER WITH LOGIN PASSWORD 'Sup3rS3cret';

#
# you can \du to list out users.
#
# allow PSTV_USER user to create db:
# ALTER ROLE PSTV_USER CREATEDB;

#\q to quit psql

# reconnect using the new user
# psql postgres -U pstv_user

# Create new database and its permission:

# CREATE DATABASE pstv_web;

# GRANT ALL PRIVILEGES ON DATABASE pstv_web TO pstv_user;

# \list
# \connect pstv_web
# \dt
# \q

# You can now create, read, update and delete data on our super_awesome_application database with the user pstv_user!

# list database
psql -U postgres -l

#
# gui tool
#
#brew install --cask --appdir="/Applications/_dev" pgadmin4
