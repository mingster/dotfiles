#!/bin/zsh

# http://alvinalexander.com/mac-os-x/mac-osx-startup-crontab-launchd-jobs
# launchctl load "/Users/$USER/Library/LaunchAgents/com.mingster.crontab.plist"

echo '----------------------------------' >> /tmp/com.mingster.crontab.out
date >> /tmp/com.mingster.crontab.out
echo '----------------------------------' >> /tmp/com.mingster.crontab.out

echo '----------------- sync git repositories -----------------' >> /tmp/com.mingster.crontab.out
sh /Users/mtsai/bin/cron_sync_git.sh >> /tmp/com.mingster.crontab.out

#echo '----------------- sync from niteKing to Bigmac -----------------' >> /tmp/com.mingster.crontab.out
#sh /Users/mtsai/bin/rsync_toBigmac.sh >> /tmp/com.mingster.crontab.out

#echo '----------------- sync from Bigmac to niteKing -----------------' >> /tmp/com.mingster.crontab.out
#sh /Users/mtsai/bin/rsync_fromBigmac.sh >> /tmp/com.mingster.crontab.out

echo '----------------- run rsync_toPi -----------------' >> /tmp/com.mingster.crontab.out
sh /Users/mtsai/bin/rsync_toPi.sh >> /tmp/com.mingster.crontab.out

#echo '----------------- run rsync_toMrWolf -----------------' >> /tmp/com.mingster.crontab.out
#sh /Users/mtsai/bin/rsync_toMrWolf.sh >> /tmp/com.mingster.crontab.out
