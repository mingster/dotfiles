#!/bin/bash
#
# https://www.codementor.io/@engineerapart/getting-started-with-postgresql-on-mac-osx-are8jcopb
# https://ravinderfzk.medium.com/install-postgresql-and-pgadmin4-in-arch-linux-eb013b45540f

sudo pacman -S postgresql
sudo passwd postgres
su postgres
initdb --locale $LANG -E UTF8 -D '/var/lib/postgres/data/'

#fish_add_path /usr/local/opt/postgresql@15/bin

sudo systemctl enable --now postgresql
sudo systemctl status postgresql

## in the psql session, type \password postgres to set the password.
#
# psql -U postgres
# \password


# CREATE NEW user
# CREATE ROLE postgres WITH LOGIN PASSWORD 'quoted password' [OPTIONS]

# in the psql sessesion, create new user as follow:
# CREATE ROLE PSTV_USER WITH LOGIN PASSWORD 'Sup3rS3cret';

# you can \du to list out users.
#
# allow PSTV_USER user to create db:
# ALTER ROLE PSTV_USER CREATEDB;

#\q to quit psql

# reconnect using the new user
# psql postgres -U pstv_user

# Create new database and its permission:

# CREATE DATABASE super_awesome_application;

# GRANT ALL PRIVILEGES ON DATABASE super_awesome_application TO pstv_user;

# \list
# \connect pstv_web
# \dt
# \q

# You can now create, read, update and delete data on our super_awesome_application database with the user pstv_user!


# list database
psql -U postgres -l

#
# install pgadmin
#
#sudo mkdir /var/lib/pgadmin
#sudo mkdir /var/log/pgadmin
#sudo chown $USER /var/lib/pgadmin
#sudo chown $USER /var/log/pgadmin

#cd
#python3 -m venv pgadmin4
