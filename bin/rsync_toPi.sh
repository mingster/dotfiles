#!/bin/zsh
sh ~/bin/cron_sync_git.sh

rsync -avz --delete --bwlimit=5000 /Volumes/data3/Users/mtsai/Documents2 mtsai@pi1:/4tb/Users/mtsai/
#rsync -avz --delete --bwlimit=5000 /Volumes/data3/Users/mtsai/gdrive mtsai@pi1:/4tb/Users/mtsai/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/Users/mtsai/Pictures mtsai@pi1:/4tb/Users/mtsai/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/Users/mtsai/projects mtsai@pi1:/4tb/Users/mtsai/

rsync -avz --delete --bwlimit=5000 ~/.ssh mtsai@pi1:/4tb/Users/mtsai/
rsync -avz --delete --bwlimit=5000 ~/.gnupg mtsai@pi1:/4tb/Users/mtsai/
rsync -avz --delete --bwlimit=5000 ~/bin mtsai@pi1:/4tb/Users/mtsai/
rsync -avz --delete --bwlimit=5000 ~/Documents mtsai@pi1:/4tb/Users/mtsai/
rsync -avz --delete --bwlimit=5000 ~/Downloads mtsai@pi1:/4tb/Users/mtsai/
rsync -avz --delete --bwlimit=5000 ~/GitHub mtsai@pi1:/4tb/Users/mtsai/
#rsync -avz --delete --bwlimit=1000 ~/Music mtsai@pi1:/4tb/Users/mtsai/

#--Movies and Music--
rsync -avz --delete --bwlimit=5000 /Volumes/data3/Media/Movies/ mtsai@pi1:/4tb/Media/Movies/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/Media/Music/ mtsai@pi1:/4tb/Media/Music/

#--plex lib--
#https://support.plex.tv/hc/en-us/articles/201370363-Move-an-Install-to-Another-System
rsync -avz --delete --bwlimit=5000 $HOME/Library/Application\ Support/Plex\ Media\ Server mtsai@pi1:/4tb/Users/mtsai/Library/Application\ Support/
#rsync -avz --delete --bwlimit=5000 ~/Library/Application\ Support/Plex\ Media\ Server/ mtsai@pi1:"/4tb/Users/mtsai/Library/Application\ Support/Plex\ Media\ Server/"
rsync -avz --delete --bwlimit=5000 ~/Library/Preferences/com.plexapp.plexmediaserver.plist mtsai@pi1:"/4tb/Users/mtsai/Library/Preferences/"

rsync -avz --delete --bwlimit=5000 /Volumes/data3/Ascertaint/ mtsai@pi1:/4tb/Ascertaint/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/Ascertaint.org/ mtsai@pi1:/4tb/Ascertaint.org/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/FileServer/ mtsai@pi1:/4tb/FileServer/

rsync -avz --delete --bwlimit=5000 /Volumes/data3/projects/ mtsai@pi1:/4tb/projects/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/src/ mtsai@pi1:/4tb/src/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/sdk/ mtsai@pi1:/4tb/sdk/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/srv/ mtsai@pi1:/4tb/srv/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/sf.net/ mtsai@pi1:/4tb/sf.net/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/Software/ mtsai@pi1:/4tb/Software/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/Software_mac/ mtsai@pi1:/4tb/Software_mac/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/STREAMING/ mtsai@pi1:/4tb/STREAMING/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/var/ mtsai@pi1:/4tb/var/
rsync -avz --delete --bwlimit=5000 /Volumes/data3/vmware/ mtsai@pi1:/4tb/vmware/
