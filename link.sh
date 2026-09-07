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

# The daemon that `maestral start` just spawned lives inside this terminal's
# session scope and dies with it. Hand it over to the systemd user unit that
# autostart created so syncing continues after this window closes.
echo "Handing the daemon over to systemd."
maestral stop >/dev/null 2>&1 || true
systemctl --user start "maestral-daemon@maestral.service"

echo
echo "Done. Dropbox now syncs through Maestral. Check the bar icon for status."
