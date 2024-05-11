
#!/bin/bash

#
# https://www.geeksforgeeks.org/how-to-install-and-configure-mysql-on-arch-based-linux-distributionsmanjaro/
#

# update system first
sudo pacman -Syu

# this will install mariadb
sudo pacman -S mysql

# verify the install
# mariadb --version

# install db
sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql

sudo systemctl start mariadb
sudo mariadb-secure-installation

# to create new db user

# sudo mysql
# CREATE USER ‘<username>’@’localhost’ IDENTIFIED BY ‘<password>’;
# GRANT ALL PRIVILEGES ON *.* TO ‘<username>’@’localhost’ WITH GRANT OPTION;
# FLUSH PRIVILEGES;
# exit

# test the new user
# mariadb -u ptest -p
