#!/bin/bash
# Installs the BudgetTracking Plaid server as a LaunchDaemon so it runs
# at boot and restarts on crash. Run with: sudo ./install.sh
set -euo pipefail

LABEL="com.schlegel.budgettracking.server"
SRC="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
DEST="/Library/LaunchDaemons/${LABEL}.plist"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

echo "Validating plist..."
plutil -lint "$SRC"

echo "Installing $DEST"
cp "$SRC" "$DEST"
chown root:wheel "$DEST"
chmod 644 "$DEST"

# Reload if already loaded (idempotent re-install).
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  echo "Already loaded — booting out first..."
  launchctl bootout "system/${LABEL}" || true
fi

echo "Bootstrapping..."
launchctl bootstrap system "$DEST"
launchctl enable "system/${LABEL}"
launchctl kickstart -k "system/${LABEL}"

echo "Done. Status:"
launchctl print "system/${LABEL}" | grep -E "state|pid|path" | head
