#!/bin/bash
set -euo pipefail

# Baseline macOS Dock configuration for managed Macs.
# This script is intended to be run as a Jamf Pro policy or manually.
#
# Optional environment variables:
#   AUTOHIDE=true|false
#   TILESIZE=48
#   ORIENTATION=bottom|left|right
#   SHOW_RECENTS=true|false
#   MAGNIFICATION=true|false
#   MAGNIFICATION_SIZE=64

AUTOHIDE="${AUTOHIDE:-true}"
TILESIZE="${TILESIZE:-48}"
ORIENTATION="${ORIENTATION:-bottom}"
SHOW_RECENTS="${SHOW_RECENTS:-false}"
MAGNIFICATION="${MAGNIFICATION:-false}"
MAGNIFICATION_SIZE="${MAGNIFICATION_SIZE:-64}"

# Apply the baseline Dock settings.
defaults write com.apple.dock autohide -bool "$AUTOHIDE"
defaults write com.apple.dock tilesize -int "$TILESIZE"
defaults write com.apple.dock orientation -string "$ORIENTATION"
defaults write com.apple.dock show-recents -bool "$SHOW_RECENTS"
defaults write com.apple.dock magnification -bool "$MAGNIFICATION"

if [ "$MAGNIFICATION" = "true" ]; then
    defaults write com.apple.dock largesize -int "$MAGNIFICATION_SIZE"
fi

# Restart the Dock so changes take effect immediately.
killall Dock >/dev/null 2>&1 || true

echo "Dock settings applied successfully."
