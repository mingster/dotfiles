#!/bin/zsh
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:"/4tb/Users/mtsai/Library/Application\ Support/Plex\ Media\ Server/" ~/Library/Application\ Support/Plex\ Media\ Server/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:"/4tb/Users/mtsai/Library/Preferences/com.plexapp.plexmediaserver.plist" ~/Library/Preferences/com.plexapp.plexmediaserver.plist

rsync -avz --delete --bwlimit=5000--exclude .AppleDouble mtsai@pi1:/4tb/Users/mtsai/Music/ ~/Music/

rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Users/mtsai/Pictures/ /Volumes/data3/Users/mtsai/Pictures/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Users/mtsai/Documents/ /Volumes/data3/Users/mtsai/Documents/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Users/mtsai/Documents2/ /Volumes/data3/Users/mtsai/Documents2/
#rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Users/mtsai/gdrive/ /Volumes/data3/Users/mtsai/gdrive/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Users/mtsai/GitHub/ /Volumes/data3/Users/mtsai/GitHub/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Users/mtsai/projects/ /Volumes/data3/Users/mtsai/projects/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Media/Movies/ /Volumes/data3/Media/Movies/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Media/Music/ /Volumes/data3/Media/Music/

rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Ascertaint/ /Volumes/data3/Ascertaint/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Ascertaint.org/ /Volumes/data3/Ascertaint.org/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/FileServer/ /Volumes/data3/FileServer/

rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/projects/ /Volumes/data3/projects/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/sbin/ /Volumes/data3/sbin/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/sdk/ /Volumes/data3/sdk/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/sf.net/ /Volumes/data3/sf.net/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Software/ /Volumes/data3/Software/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/Software_mac/ /Volumes/data3/Software_mac/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/STREAMING/ /Volumes/data3/STREAMING/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/src/ /Volumes/data3/src/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/var/ /Volumes/data3/var/
rsync -avz --delete --bwlimit=5000 --exclude .AppleDouble mtsai@pi1:/4tb/vmware/ /Volumes/data3/vmware/
