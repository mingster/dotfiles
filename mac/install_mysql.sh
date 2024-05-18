
#!/bin/bash

#
# https://myapollo.com.tw/blog/install-mysql-using-homebrew/
# https://www.geeksforgeeks.org/how-to-install-and-configure-mysql-on-arch-based-linux-distributionsmanjaro/
#

# this will install mariadb
brew install mysql mycli


brew services start mysql

# set root password
mysql_secure_installation

# to create new db user
# https://docs.rackspace.com/docs/create-a-new-user-and-grant-permissions-in-mysql

# mysql -u root 
# create database tutorialdb;
# create user 'tutorialuser'@'localhost' identified by 'tutorialuser';
# grant all on tutorialdb.* to 'tutorialuser'@'localhost';
# exit

# test the new user
# mysql -u tutorialuser -p

#sudo mysqld_safe --skip-grant-tables;
#GRANT ALL PRIVILEGES ON *.* TO root@localhost WITH GRANT OPTION;
