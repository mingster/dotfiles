#!/bin/bash

# https://wiki.archlinux.org/title/MongoDB
yay -S mongodb-bin

yay -S mongodb-compass

systemctl start mongodb

ps aux | grep -v grep | grep mongo

# replication

#sudo nano /etc/mongod.conf

#replication:
#replSetName: rs0
