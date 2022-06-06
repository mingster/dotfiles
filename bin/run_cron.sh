#!/bin/zsh
launchctl load "/Users/$USER/Library/LaunchAgents/com.mingster.crontab.plist"

#launchctl start com.mingster.crontab

launchctl list | grep mingster
