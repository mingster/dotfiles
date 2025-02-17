#!/bin/bash

echo "Starting the uninstallation of Microsoft Office..."

# Ask for the administrator password upfront.
sudo -v

# Quit all Microsoft Office applications
echo "Closing all Microsoft Office applications..."
osascript -e 'quit app "Microsoft Word"'
osascript -e 'quit app "Microsoft Excel"'
osascript -e 'quit app "Microsoft PowerPoint"'
osascript -e 'quit app "Microsoft Outlook"'
osascript -e 'quit app "Microsoft OneNote"'

# Remove Office applications from the Applications folder
echo "Removing Office applications from the Applications folder..."
rm -rf /Applications/Microsoft\ Word.app
rm -rf /Applications/Microsoft\ Excel.app
rm -rf /Applications/Microsoft\ PowerPoint.app
rm -rf /Applications/Microsoft\ Outlook.app
rm -rf /Applications/Microsoft\ OneNote.app

# Remove related files from the user's Library folder
echo "Removing related files from the Library folder..."
sudo rm -rf ~/Library/Containers/com.microsoft.errorreporting
sudo rm -rf ~/Library/Containers/com.microsoft.Excel
sudo rm -rf ~/Library/Containers/com.microsoft.Outlook
sudo rm -rf ~/Library/Containers/com.microsoft.Powerpoint
sudo rm -rf ~/Library/Containers/com.microsoft.Word
sudo rm -rf ~/Library/Containers/com.microsoft.onenote.mac

# Remove Group Containers
echo "Removing Group Containers..."
sudo rm -rf ~/Library/Group\ Containers/UBF8T346G9.ms
sudo rm -rf ~/Library/Group\ Containers/UBF8T346G9.Office
sudo rm -rf ~/Library/Group\ Containers/UBF8T346G9.OfficeOsfWebHost

# Remove additional Microsoft preferences and cached data (optional)
echo "Removing additional preferences and cached data..."
sudo rm -rf ~/Library/Application\ Support/Microsoft
sudo rm -rf ~/Library/Preferences/com.microsoft.*
sudo rm -rf ~/Library/Caches/com.microsoft.*

# Final cleanup
echo "Emptying Trash..."
osascript -e 'tell application "Finder" to empty trash'

echo "Restarting Finder to apply changes..."
killall Finder

echo "Microsoft Office has been completely uninstalled!"
