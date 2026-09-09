#!/bin/bash
# Shared by install.sh and uninstall.sh: where the Maestral virtualenv may live.
#
# The venv location can be overridden with MAESTRAL_VENV, and `uninstall.sh
# --purge` deletes that directory recursively. An inherited, mistyped, or
# malicious value must therefore never be able to point the scripts at
# something like $HOME or /. Two rules enforce that:
#
#   1. The venv must resolve (symlinks included) to a real subdirectory of
#      ~/.local/share. Nothing outside that parent is ever created or removed.
#   2. install.sh stamps every venv it creates with a marker file, and purge
#      refuses to delete a directory that lacks the marker or is not a venv.
#
# Source this file; do not run it.

PLUGIN_ID="io.github.ryankv.omarchy-maestral"
VENV_PARENT="$HOME/.local/share"
VENV_DEFAULT="$VENV_PARENT/maestral-venv"
VENV_MARKER=".omarchy-maestral-venv"

# resolve_venv_dir PATH
# Print the canonical form of PATH if it is an acceptable venv location,
# otherwise explain why on stderr and return 1.
resolve_venv_dir() {
  local requested=$1 parent resolved
  if [[ -z ${HOME:-} || $HOME != /* ]]; then
    echo "HOME must be set to an absolute path." >&2
    return 1
  fi
  if [[ -z $requested || $requested != /* ]]; then
    echo "MAESTRAL_VENV must be an absolute path, got '$requested'." >&2
    return 1
  fi
  parent=$(realpath -m -- "$VENV_PARENT") || return 1
  resolved=$(realpath -m -- "$requested") || return 1
  if [[ $resolved != "$parent"/?* ]]; then
    echo "Refusing to use '$requested': the Maestral venv must be a directory inside $VENV_PARENT." >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

# purge_target PATH
# Like resolve_venv_dir, but additionally require that the directory exists,
# is a Python virtualenv, and carries the marker install.sh wrote. Print the
# canonical path on success.
purge_target() {
  local venv
  venv=$(resolve_venv_dir "$1") || return 1
  if [[ ! -d $venv ]]; then
    echo "Nothing to purge: $venv does not exist." >&2
    return 1
  fi
  if [[ ! -f $venv/pyvenv.cfg ]]; then
    echo "Refusing to delete $venv: it is not a Python virtualenv." >&2
    return 1
  fi
  if [[ ! -f $venv/$VENV_MARKER || $(<"$venv/$VENV_MARKER") != "$PLUGIN_ID" ]]; then
    echo "Refusing to delete $venv: it was not created by this plugin's install.sh." >&2
    echo "Re-run install.sh once to stamp an older install, or remove the directory by hand." >&2
    return 1
  fi
  printf '%s\n' "$venv"
}
