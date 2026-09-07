#!/bin/bash
# Stop Maestral, disable the bar widget, and optionally remove the Maestral install.
#
#   ./uninstall.sh          # stop syncing, disable autostart, disable the widget
#   ./uninstall.sh --purge  # also delete the Maestral virtualenv and command link
#
# Your Dropbox folder and Maestral's own config (~/.config/maestral) are never
# touched. Remove them by hand if you want them gone.

set -uo pipefail

PLUGIN_ID="io.github.ryankv.omarchy-maestral"
VENV="${MAESTRAL_VENV:-$HOME/.local/share/maestral-venv}"
BIN_DIR="$HOME/.local/bin"

if command -v maestral >/dev/null 2>&1; then
  maestral stop >/dev/null 2>&1 || true
  maestral autostart -N >/dev/null 2>&1 || true
fi

command -v omarchy-plugin-disable >/dev/null 2>&1 && omarchy-plugin-disable "$PLUGIN_ID" || true

if [[ ${1:-} == --purge ]]; then
  [[ -L $BIN_DIR/maestral ]] && rm -f "$BIN_DIR/maestral"
  [[ -d $VENV ]] && rm -rf "$VENV"
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-maestral"
  echo "Removed Maestral from $VENV."
fi

echo "Dropbox via Maestral is disabled. Remove the plugin itself with: omarchy plugin remove $PLUGIN_ID"
