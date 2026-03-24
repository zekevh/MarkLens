#!/usr/bin/env bash
# Usage:
#   ./scripts/bump-version.sh           — increments CFBundleVersion only (build number)
#   ./scripts/bump-version.sh 1.2       — also sets CFBundleShortVersionString
#
# Run this before archiving/submitting. Commit the result.
set -euo pipefail

PLIST="$(dirname "$0")/../Info.plist"

# Bump build number
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW=$(( CURRENT + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW" "$PLIST"
echo "CFBundleVersion: $CURRENT → $NEW"

# Optionally set marketing version
if [[ $# -ge 1 ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$PLIST"
    echo "CFBundleShortVersionString → $1"
fi
