#!/bin/bash
#
# https://www.codementor.io/@engineerapart/getting-started-with-postgresql-on-mac-osx-are8jcopb
# https://ravinderfzk.medium.com/install-postgresql-and-pgadmin4-in-arch-linux-eb013b45540f

# uninstall
# sudo systemctl stop postgresql
# sudo pacman -Rns postgresql
# sudo rm -rf /var/lib/postgresql/
# sudo rm -rf /var/log/postgresql/

# install
sudo pacman -S postgresql
postgres --version

sudo passwd postgres
su postgres
#initdb --locale $LANG -E UTF8 -D '/var/lib/postgres/data/'
initdb --locale en_US.UTF-8 -D /var/lib/postgres/data --data-checksums
#sudo -u postgres initdb --locale en_US.UTF-8 -D /var/lib/postgres/data --data-checksums

#fish_add_path /usr/local/opt/postgresql@18/bin

sudo systemctl enable --now postgresql
sudo systemctl status postgresql

## in the psql session, type \password postgres to set the password.
#
psql -U postgres
\password

# CREATE NEW user
# CREATE ROLE postgres WITH LOGIN PASSWORD 'quoted password' [OPTIONS]

# in the psql sessesion, create new user as follow:
CREATE ROLE PSTV_USER WITH LOGIN PASSWORD 'Sup3rS3cret';

# you can \du to list out users.
#
# allow PSTV_USER user to create db:
ALTER ROLE PSTV_USER CREATEDB;

#\q to quit psql

# reconnect using the new user
psql postgres -U pstv_user

# Create new database and its permission:

CREATE DATABASE riben_life;
GRANT ALL PRIVILEGES ON DATABASE riben_life TO pstv_user;

# \list
# \connect riben_life
# \dt
# \q

# You can now create, read, update and delete data on our super_awesome_application database with the user pstv_user!

# list database
psql -U postgres -l

# sudo nano /var/lib/postgres/data/pg_hba.conf
#add allow host
#host all     all     192.168.2.5/32  scram-sha-256

# sudo nano /var/lib/postgres/data/postgresql.conf
# listen_addresses = '*'
# port = 5432

#sudo pacman -S certbot
#sudo certbot certonly --standalone -d miniu.mingster.com --key-type rsa

sudo ufw allow 5432
sudo ufw status numbered

sudo systemctl restart postgresql
sudo systemctl status postgresql

# test remote access
psql -h miniu -U postgres -d postgres

#
# install pgadmin
#
#sudo mkdir /var/lib/pgadmin
#sudo mkdir /var/log/pgadmin
#sudo chown $USER /var/lib/pgadmin
#sudo chown $USER /var/log/pgadmin

#cd
#python3 -m venv pgadmin4
