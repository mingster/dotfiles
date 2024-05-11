
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

# mysql -u root -p
# CREATE USER '<username>'@'localhost' IDENTIFIED BY '<password>';
# GRANT ALL PRIVILEGES ON *.* TO <username>@localhost WITH GRANT OPTION;
# FLUSH PRIVILEGES;
# exitmysql

# test the new user
# mysql -u <username> -p

#sudo mysqld_safe --skip-grant-tables;
#GRANT ALL PRIVILEGES ON *.* TO root@localhost WITH GRANT OPTION;
