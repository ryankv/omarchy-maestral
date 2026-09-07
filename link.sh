#!/bin/bash
# Link a Dropbox account to Maestral and start syncing.
#
# Runs inside a floating Omarchy terminal because Maestral's link flow is
# interactive: it opens the Dropbox authorisation page, asks you to paste the
# auth code back, then asks where the Dropbox folder should live and which
# folders to sync.

set -uo pipefail

if ! command -v maestral >/dev/null 2>&1; then
  echo "maestral is not installed. Run install.sh from the plugin folder first."
  exit 1
fi

echo "Linking your Dropbox account through Maestral."
echo

# If a daemon is already up but unlinked, `maestral start` only reports that it
# is running. Stop it so start runs the full first-run dialog.
maestral stop >/dev/null 2>&1 || true

maestral start || exit $?

echo
echo "Enabling Maestral autostart on login."
maestral autostart -Y

echo
echo "Done. Dropbox now syncs through Maestral. Check the bar icon for status."
