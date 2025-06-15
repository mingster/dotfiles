
#!/bin/bash

#
# https://www.geeksforgeeks.org/how-to-install-and-configure-mysql-on-arch-based-linux-distributionsmanjaro/
#

# update system first
sudo pacman -Syu

# install SQL Server and tools
yay -Syy mssql-server

# Initialize SQL Server.
sudo /opt/mssql/bin/mssql-conf setup

# The service should now be up and running, so let's check it out:
systemctl status mssql-server.service

# Configure the Firewall: #If using firewalld, allow traffic on port 1433:
sudo ufw allow 1433

# Install sqlcmd for command-line access:

#sudo pacman -S mssql-tools

# Verify Installation: Connect to the SQL Server instance using sqlcmd:

#sqlcmd -S localhost -U SA -P "<YourPassword>"

#Replace <YourPassword> with the SA password you set during setup.
#You should be able to run SQL queries at the 1> prompt.

# dat location: /var/opt/mssql/data
