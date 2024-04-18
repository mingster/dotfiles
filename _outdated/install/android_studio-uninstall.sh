#!/usr/bin/env bash

# Deletes the Android Studio application
rm -rf /Applications/_dev/Android\ Studio.app
# Delete All Android Studio related preferences
# The asterisk here should target all folders/files beginning with the string before it
rm -rf ~/Library/Preferences/AndroidStudio*
rm -rf ~/Library/Preferences/Google/AndroidStudio*
# Deletes Studio's plist file
rm -rf ~/Library/Preferences/com.google.android.*
# Deletes Emulator's plist file
rm -rf ~/Library/Preferences/com.android.*
# Deletes main plugins
rm -rf ~/Library/Application\ Support/AndroidStudio*
rm -rf ~/Library/Application\ Support/Google/AndroidStudio*
# Deletes all logs that Android Studio outputs
rm -rf ~/Library/Logs/AndroidStudio*
rm -rf ~/Library/Logs/Google/AndroidStudio*
# Deletes Android Studio's caches
rm -rf ~/Library/Caches/AndroidStudio*
# Deletes older versions of Android Studio (if any)
rm -rf ~/.AndroidStudio*

# 
rm -rf ~/.android
rm -rf ~/.gradle
