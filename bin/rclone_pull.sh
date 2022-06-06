#!/bin/sh
rclone sync --bwlimit=1M gdrive:projects /data3/projects/
rclone sync --bwlimit=1M gdrive:FileServer /data3/FileServer/
rclone sync --bwlimit=1M gdrive:Users/mtsai/Documents /data3/Users/mtsai/Documents/
rclone sync --bwlimit=1M gdrive:Users/mtsai/Documents2 /data3/Users/mtsai/Documents2/

rclone sync --bwlimit=1M gdrive:Music /data3/Media/Music/
rclone sync --bwlimit=1M gdrive:Movies /data3/Media/Movies/

rclone sync --bwlimit=1M gdrive:Ascertaint /data3/Ascertaint/
rclone sync --bwlimit=1M gdrive:Software /data3/Software/
rclone sync --bwlimit=1M gdrive:Software_mac /data3/Software_mac/
rclone sync --bwlimit=1M gdrive:vmware /data3/vmware/
rclone sync --bwlimit=1M gdrive:STREAMING /data3/STREAMING/
rclone sync --bwlimit=1M gdrive:var /data3/var/
rclone sync --bwlimit=1M gdrive:src /data3/src/
rclone sync --bwlimit=1M gdrive:srv /data3/srv/
