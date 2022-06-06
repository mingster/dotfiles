#!/usr/bin/sh

rsync -avz --delete --bwlimit=500 ~/bin/ mtsai@tpe1:~/bin/
rsync -avz --delete --bwlimit=500 ~/GitHub/ mtsai@tpe1:~/GitHub/
rsync -avz --delete --bwlimit=500 ~/Downloads/ mtsai@tpe1:~/Downloads/
rsync -avz --delete --bwlimit=500 ~/Music/ mtsai@tpe1:~/Music/

rsync -avz --delete --bwlimit=500 /Volumes/data3/Users/mtsai/Pictures/ mtsai@tpe1:/Volumes/data3/Users/mtsai/Pictures/
rsync -avz --delete --bwlimit=500 /Volumes/data3/Users/mtsai/Documents/ mtsai@tpe1:/Volumes/data3/Users/mtsai/Documents/
rsync -avz --delete --bwlimit=500 /Volumes/data3/Users/mtsai/Documents2/ mtsai@tpe1:/Volumes/data3/Users/mtsai/Documents2/

rsync -avz --delete --bwlimit=500 /Volumes/data3/Media/Music/ mtsai@tpe1:/Volumes/data3/Media/Music/
rsync -avz --delete --bwlimit=500 /Volumes/data3/Media/Movies/ mtsai@tpe1:/Volumes/data3/Media/Movies/

rsync -avz --delete --bwlimit=500 /Volumes/data3/Ascertaint/ mtsai@tpe1:/Volumes/data3/Ascertaint/
rsync -avz --delete --bwlimit=500 /Volumes/data3/Ascertaint.org/ mtsai@tpe1:/Volumes/data3/Ascertaint.org/
rsync -avz --delete --bwlimit=500 /Volumes/data3/FileServer/ mtsai@tpe1:/Volumes/data3/FileServer/
#rsync -avz --delete --bwlimit=500 /Volumes/data3/PlaceShifting/ mtsai@tpe1:/Volumes/data3/PlaceShifting/

rsync -avz --delete --bwlimit=500 /Volumes/data3/projects/ mtsai@tpe1:/Volumes/data3/projects/
rsync -avz --delete --bwlimit=500 /Volumes/data3/src/ mtsai@tpe1:/Volumes/data3/src/
rsync -avz --delete --bwlimit=500 /Volumes/data3/srv/ mtsai@tpe1:/Volumes/data3/srv/
rsync -avz --delete --bwlimit=500 /Volumes/data3/sdk/ mtsai@tpe1:/Volumes/data3/sdk/
rsync -avz --delete --bwlimit=500 /Volumes/data3/sf.net/ mtsai@tpe1:/Volumes/data3/sf.net/
rsync -avz --delete --bwlimit=500 /Volumes/data3/Software/ mtsai@tpe1:/Volumes/data3/Software/
rsync -avz --delete --bwlimit=500 /Volumes/data3/Software_mac/ mtsai@tpe1:/Volumes/data3/Software_mac/
rsync -avz --delete --bwlimit=500 /Volumes/data3/STREAMING/ mtsai@tpe1:/Volumes/data3/STREAMING/
rsync -avz --delete --bwlimit=500 /Volumes/data3/var/ mtsai@tpe1:/Volumes/data3/var/
rsync -avz --delete --bwlimit=500 /Volumes/data3/vmware/ mtsai@tpe1:/Volumes/data3/vmware/
#rsync -avz --delete --bwlimit=500 /Volumes/160gb/av/ mtsai@tpe1:/Volumes/data3/Media/av/
