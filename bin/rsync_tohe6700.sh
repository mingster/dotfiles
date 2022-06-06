#!/usr/bin/sh
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Users/mtsai/ mtsai@he6700:/cygdrive/e/Users/mtsai/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Media/Music/ mtsai@he6700:/cygdrive/e/Media/Music/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Media/Movies/ mtsai@he6700:/cygdrive/e/Media/Movies/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Media/vd/ mtsai@he6700:/cygdrive/e/Media/vd/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Ascertaint/ mtsai@he6700:/cygdrive/e/Ascertaint/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Ascertaint.org/ mtsai@he6700:/cygdrive/e/Ascertaint.org/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/FileServer/ mtsai@he6700:/cygdrive/e/FileServer/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/PlaceShifting/ mtsai@he6700:/cygdrive/e/PlaceShifting/

rsync -avz --delete --bwlimit=1000 /Volumes/backup/projects/ mtsai@he6700:/cygdrive/e/projects/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/sbin/ mtsai@he6700:/cygdrive/e/sbin/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/sdk/ mtsai@he6700:/cygdrive/e/sdk/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/sf.net/ mtsai@he6700:/cygdrive/e/sf.net/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Software/ mtsai@he6700:/cygdrive/e/Software/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/Software_mac/ mtsai@he6700:/cygdrive/e/Software_mac/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/STREAMING/ mtsai@he6700:/cygdrive/e/STREAMING/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/src/ mtsai@he6700:/cygdrive/e/src/
rsync -avz --delete --bwlimit=1000 /Volumes/backup/var/ mtsai@he6700:/cygdrive/e/var/
#rsync -avz --delete --bwlimit=1000 /Volumes/backup/vmware/ mtsai@he6700:/cygdrive/e/vmware/
