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
# The venv location can be changed, but it must be a directory inside
# ~/.local/share so that uninstall.sh --purge can never be pointed at anything
# broader (see venv-path.sh):
#
#   MAESTRAL_VENV=~/.local/share/venvs/maestral ./install.sh

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=venv-path.sh
source "$PLUGIN_DIR/venv-path.sh"

VENV=$(resolve_venv_dir "${MAESTRAL_VENV:-$VENV_DEFAULT}") || exit 1
BIN_DIR="$HOME/.local/bin"
REQUIREMENTS="$PLUGIN_DIR/requirements.txt"

existing=$(command -v maestral 2>/dev/null || true)
if [[ -n $existing && $existing != "$BIN_DIR/maestral" ]]; then
  echo "Using the maestral already on PATH: $existing"
else
  [[ -f $REQUIREMENTS ]] || { echo "Missing $REQUIREMENTS; the plugin checkout is incomplete." >&2; exit 1; }
  echo "Installing Maestral into $VENV ..."
  python3 -m venv "$VENV"
  # Stamp the venv so uninstall.sh --purge can prove this plugin created it.
  printf '%s\n' "$PLUGIN_ID" > "$VENV/$VENV_MARKER"
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
