#!/bin/bash
# Stop Maestral, disable the bar widget, and optionally remove the Maestral install.
#
#   ./uninstall.sh          # stop syncing, disable autostart, disable the widget
#   ./uninstall.sh --purge  # also delete the Maestral virtualenv and command link
#
# --purge only ever deletes a directory inside ~/.local/share/omarchy-maestral
# that is a Python virtualenv stamped by install.sh for that exact path.
# Anything else, including a MAESTRAL_VENV that points somewhere broader, is
# refused before anything is touched.
#
# Your Dropbox folder and Maestral's own config (~/.config/maestral) are never
# touched. Remove them by hand if you want them gone.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=venv-path.sh
source "$PLUGIN_DIR/venv-path.sh"

CONFIG_NAME="${MAESTRAL_CONFIG_NAME:-maestral}"
BIN_DIR="$HOME/.local/bin"
purge=false
venv=""

if [[ ${1:-} == --purge ]]; then
  purge=true
  # Validate the deletion target up front so a bad path aborts the whole run.
  venv=$(purge_target "${MAESTRAL_VENV:-$VENV_DEFAULT}") || {
    echo "Nothing was removed." >&2
    exit 1
  }
fi

if command -v maestral >/dev/null 2>&1; then
  maestral stop --config-name "$CONFIG_NAME" >/dev/null 2>&1 || true
  maestral autostart -N --config-name "$CONFIG_NAME" >/dev/null 2>&1 || true
fi

command -v omarchy-plugin-disable >/dev/null 2>&1 && omarchy-plugin-disable "$PLUGIN_ID" || true

if $purge; then
  link="$BIN_DIR/maestral"
  # Only drop the command link if it points into the venv being removed.
  if [[ -L $link && $(realpath -m -- "$link") == "$venv/bin/maestral" ]]; then
    rm -f -- "$link"
  fi
  rm -rf -- "$venv"
  rm -rf -- "$(cache_dir)"
  echo "Removed Maestral from $venv."
fi

echo "Dropbox via Maestral is disabled. Remove the plugin itself with: omarchy plugin remove $PLUGIN_ID"
