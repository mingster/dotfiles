#!/bin/bash

# https://wiki.archlinux.org/title/MongoDB
yay -S mongodb-bin

yay -S mongodb-compass

su -V
# replication
#sudo nano /etc/mongodb.conf
sudo echo "replication:" >> /etc/mongodb.conf
sudo echo "    replSetName: rs0" >> /etc/mongodb.conf

#replication:
#replSetName: rs0

systemctl start mongodb
ps aux | grep -v grep | grep mongo

systemctl status mongodb
