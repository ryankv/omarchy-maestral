#!/bin/bash
# Install Maestral (open-source Dropbox client) and enable the bar widget.
#
# Maestral is a Python application. It is installed into its own virtualenv
# under ~/.local/share/omarchy-maestral so it never touches system Python
# packages, and the `maestral` command is linked into ~/.local/bin.
#
# Maestral and every package it pulls in are pinned in requirements.txt with
# sha256 hashes. pip runs in hash-checking mode, so this commit always installs
# exactly the artifacts that were reviewed, never whatever PyPI serves later.
# See requirements.txt for how to refresh the pins.
#
# The venv location can be changed, but it must be a directory inside
# ~/.local/share/omarchy-maestral that is absent, empty, or a venv this script
# built earlier, so that neither this script nor uninstall.sh --purge can ever
# be pointed at something else (see venv-path.sh):
#
#   MAESTRAL_VENV=~/.local/share/omarchy-maestral/py314 ./install.sh

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=venv-path.sh
source "$PLUGIN_DIR/venv-path.sh"

VENV=$(install_target "${MAESTRAL_VENV:-$VENV_DEFAULT}") || exit 1
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/maestral"
REQUIREMENTS="$PLUGIN_DIR/requirements.txt"

existing=$(command -v maestral 2>/dev/null || true)
if [[ -n $existing && $existing != "$LINK" ]]; then
  echo "Using the maestral already on PATH: $existing"
else
  [[ -f $REQUIREMENTS ]] || { echo "Missing $REQUIREMENTS; the plugin checkout is incomplete." >&2; exit 1; }
  # Never replace a maestral command the user put in ~/.local/bin themselves;
  # only our own link into the venv may be rewritten.
  if ! command_link_replaceable "$LINK" "$VENV"; then
    echo "Refusing to replace $LINK: it is not this plugin's link into $VENV." >&2
    echo "Move it aside, or put that maestral earlier on PATH so it is used as is." >&2
    exit 1
  fi
  echo "Installing Maestral into $VENV ..."
  python3 -m venv "$VENV"
  # Stamp the venv so uninstall.sh --purge can prove this script created it here.
  write_marker "$VENV"
  "$VENV/bin/pip" install --quiet --require-hashes --requirement "$REQUIREMENTS"
  mkdir -p "$BIN_DIR"
  ln -sfn "$VENV/bin/maestral" "$LINK"
  echo "Linked $LINK"
fi

echo "Maestral $("$LINK" --version 2>/dev/null || maestral --version)"

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
