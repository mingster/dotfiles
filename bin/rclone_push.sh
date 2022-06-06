#!/bin/sh
rclone sync --bwlimit=1M /data3/projects/ gdrive:projects
rclone sync --bwlimit=1M /data3/FileServer/ gdrive:FileServer
rclone sync --bwlimit=1M /data3/Users/mtsai/Documents/ gdrive:Users/mtsai/Documents
rclone sync --bwlimit=1M /data3/Users/mtsai/Documents2/ gdrive:Users/mtsai/Documents2

rclone sync --bwlimit=1M /data3/Media/Music/ gdrive:Music
rclone sync --bwlimit=1M /data3/Media/Movies/ gdrive:Movies

rclone sync --bwlimit=1M /data3/Ascertaint/ gdrive:Ascertaint
rclone sync --bwlimit=1M /data3/Software/ gdrive:Software
rclone sync --bwlimit=1M /data3/Software_mac/ gdrive:Software_mac
rclone sync --bwlimit=1M /data3/vmware/ gdrive:vmware
rclone sync --bwlimit=1M /data3/STREAMING/ gdrive:STREAMING
rclone sync --bwlimit=1M /data3/var/ gdrive:var
rclone sync --bwlimit=1M /data3/src/ gdrive:src
rclone sync --bwlimit=1M /data3/srv/ gdrive:srv
