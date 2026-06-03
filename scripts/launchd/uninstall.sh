#!/bin/bash
# Stops and removes the BudgetTracking LaunchDaemon. Run: sudo ./uninstall.sh
set -euo pipefail

LABEL="com.schlegel.budgettracking.server"
DEST="/Library/LaunchDaemons/${LABEL}.plist"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

launchctl bootout "system/${LABEL}" 2>/dev/null || true
rm -f "$DEST"
echo "Removed $DEST"
