#!/bin/sh

#--plex lib--
#https://support.plex.tv/hc/en-us/articles/201370363-Move-an-Install-to-Another-System
rsync -avz --delete --bwlimit=5000 ~/Library/Application\ Support/Plex\ Media\ Server/ mtsai@pi1:"/4tb/Users/mtsai/Library/Application Support/Plex Media Server/"
rsync -avz --delete --bwlimit=5000 ~/Library/Preferences/com.plexapp.plexmediaserver.plist mtsai@pi1:"/4tb/Users/mtsai/Library/Preferences/com.plexapp.plexmediaserver.plist"

rsync -avz --delete --bwlimit=5000 ~/GitHub/ mtsai@bigmac:~/GitHub/
rsync -avz --delete --bwlimit=5000 ~/Downloads/ mtsai@bigmac:~/Downloads/
