#!/usr/bin/env bash


#
# https://myapollo.com.tw/blog/install-mysql-using-homebrew/
# https://www.geeksforgeeks.org/how-to-install-and-configure-mysql-on-arch-based-linux-distributionsmanjaro/
# https://gist.github.com/Foadsf/b351fe7686de19a4c91d3e0b4c91080a

brew install mysql
# brew install mycli

# set root password
mysql_secure_installation

# this only works after you allow background access
brew services restart mysql

# brew services start mysql

# thr process
# /usr/local/opt/mysql/bin/mysqld --basedir=/usr/local/opt/mysql --datadir=/usr/local/var/mysql
# --plugin-dir=/usr/local/opt/mysql/lib/plugin --log-error=niteking.local.err --pid-file=niteking.local.pid

## result:
#==> /usr/local/Cellar/mysql/8.3.0_1/bin/mysqld --initialize-insecure --user=mtsai --basedir=/usr/local/Cellar/mysql/8.3.0_1 --datadir=/usr/local/var/mysql --tmpdir=/tmp


# to create new db user
# https://docs.rackspace.com/docs/create-a-new-user-and-grant-permissions-in-mysql

# mysql -u root
# create database tutorialdb;
# create user 'dev'@'localhost' identified by 'dev4fun!';
# grant all on tutorialdb.* to 'tutorialuser'@'localhost';
# exit

# test the new user
# mysql -u tutorialuser -p

# sudo mysqld_safe --skip-grant-tables;
# GRANT ALL PRIVILEGES ON *.* TO root@localhost WITH GRANT OPTION;
