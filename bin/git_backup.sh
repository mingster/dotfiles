#!/bin/sh
rsync -avz --delete --bwlimit=1000 root@stmjph3.tvcdn.org:/srv/git/ /data3/srv/git/
