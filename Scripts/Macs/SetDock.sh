#!/bin/zsh

dockutilbin=$(/usr/bin/dockutil)
loggedInUser=$(echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')
loggedInUserPlist="/Users/$loggedInUser/Library/Preferences/com.apple.dock.plist"

#Remove all from Dock
$dockutilbin --remove all --no-restart $loggedInUserPlist; sleep 2

#Add Applications to Dock

#Add Microsoft Teams
$dockutilbin --add file:///Applications/Microsoft\ Teams.app --no-restart $loggedInUserPlist

#Add Microsoft Outlook
$dockutilbin --add file:///Applications/Microsoft\ Outlook.app --no-restart $loggedInUserPlist

#Add Microsoft Word
$dockutilbin --add file:///Applications/Microsoft\ Word.app --no-restart $ loggedInUserPlist

#Add Microsoft Excel
$dockutilbin --add file:///Applications/Microsoft\ Excel.app --no-restart $ loggedInUserPlist

#Add Microsoft PowerPoint
$dockutilbin --add file:///Applications/Microsoft\ PowerPoint.app --no-restart $loggedInUserPlist

#Add System Preferences
$dockutilbin --add file:///Applications/System\ Preferences.app --no-restart $loggedInUserPlist

#Add Downloads folder
$dockutilbin --add '~/Downloads' --view grid --display folder $loggedInUserPlist