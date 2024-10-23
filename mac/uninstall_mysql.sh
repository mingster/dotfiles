
#!/bin/bash


brew remove mysql
brew cleanup

sudo rm -rf /usr/local/mysql*
sudo rm ~/Library/LaunchAgents/homebrew.mxcl.mysql.plist
sudo rm -rf /Library/StartupItems/MySQLCOM
sudo rm -rf /Library/PreferencePanes/My*

sudo rm -rf /usr/local/etc/my.cnf.*

# data dir
sudo rm -rf /usr/local/var/mysql
