#!/bin/bash
# Install Maestral (open-source Dropbox client) and enable the bar widget.
#
# Maestral is a Python application. It is installed into its own virtualenv
# under ~/.local/share/maestral-venv so it never touches system Python
# packages, and the `maestral` command is linked into ~/.local/bin.
#
# Maestral and every package it pulls in are pinned in requirements.txt with
# sha256 hashes. pip runs in hash-checking mode, so this commit always installs
# exactly the artifacts that were reviewed, never whatever PyPI serves later.
# See requirements.txt for how to refresh the pins.
#
#   MAESTRAL_VENV=/some/path ./install.sh   # choose another venv location

set -euo pipefail

PLUGIN_ID="io.github.ryankv.omarchy-maestral"
VENV="${MAESTRAL_VENV:-$HOME/.local/share/maestral-venv}"
BIN_DIR="$HOME/.local/bin"
PLUGIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REQUIREMENTS="$PLUGIN_DIR/requirements.txt"

existing=$(command -v maestral 2>/dev/null || true)
if [[ -n $existing && $existing != "$BIN_DIR/maestral" ]]; then
  echo "Using the maestral already on PATH: $existing"
else
  [[ -f $REQUIREMENTS ]] || { echo "Missing $REQUIREMENTS; the plugin checkout is incomplete." >&2; exit 1; }
  echo "Installing Maestral into $VENV ..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --require-hashes --requirement "$REQUIREMENTS"
  mkdir -p "$BIN_DIR"
  ln -sfn "$VENV/bin/maestral" "$BIN_DIR/maestral"
  echo "Linked $BIN_DIR/maestral"
fi

echo "Maestral $("$BIN_DIR/maestral" --version 2>/dev/null || maestral --version)"

if command -v omarchy-plugin-enable >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null; then
    omarchy-plugin-enable "$PLUGIN_ID" || true
  else
    echo "Plugin $PLUGIN_ID is not registered with the shell yet."
    echo "Add it with: omarchy plugin add https://github.com/ryankv/omarchy-maestral.git --enable"
  fi
fi

echo
echo "Next: click the Dropbox icon in the bar and choose Login, or run: maestral start"
