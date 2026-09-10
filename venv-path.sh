#!/bin/bash
# Shared by install.sh and uninstall.sh: where the Maestral virtualenv may live,
# what install.sh may create, and what `uninstall.sh --purge` may delete.
#
# The venv location can be overridden with MAESTRAL_VENV. install.sh builds a
# virtualenv there and --purge removes it recursively, so an inherited,
# mistyped, or malicious value must never be able to point either script at a
# directory that belongs to something else. Three rules enforce that:
#
#   1. The venv must resolve (symlinks included) to a real subdirectory of
#      ~/.local/share/omarchy-maestral, a parent this plugin alone owns.
#      Nothing outside it is ever created or removed.
#   2. install.sh only builds into a path that does not exist yet, an empty
#      directory, or a virtualenv it stamped earlier. It never adopts a
#      directory that already holds something.
#   3. The stamp names this plugin and the exact directory it was written for,
#      and --purge deletes only a virtualenv whose stamp matches. A stamp
#      copied into another directory does not validate that directory.
#
# Source this file; do not run it.

PLUGIN_ID="io.github.ryankv.omarchy-maestral"
VENV_PARENT="$HOME/.local/share/omarchy-maestral"
VENV_DEFAULT="$VENV_PARENT/venv"
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

# write_marker VENV
# Stamp VENV as created by this plugin for exactly that path.
write_marker() {
  printf '%s\n%s\n' "$PLUGIN_ID" "$1" > "$1/$VENV_MARKER"
}

# marker_matches VENV
# True if VENV carries a stamp naming this plugin and this exact directory.
marker_matches() {
  local venv=$1 id path
  [[ -f $venv/$VENV_MARKER ]] || return 1
  { IFS= read -r id && IFS= read -r path; } < "$venv/$VENV_MARKER" || return 1
  [[ $id == "$PLUGIN_ID" && $path == "$venv" ]]
}

# dir_is_empty DIR
dir_is_empty() {
  ( shopt -s nullglob dotglob; set -- "$1"/*; (( $# == 0 )) )
}

# install_target PATH
# Like resolve_venv_dir, but additionally require that install.sh may build a
# virtualenv there: the path is absent, an empty directory, or a virtualenv
# this plugin stamped. Print the canonical path on success.
install_target() {
  local venv
  venv=$(resolve_venv_dir "$1") || return 1
  if [[ -e $venv || -L $venv ]]; then
    if [[ ! -d $venv ]]; then
      echo "Refusing to use $venv: it exists and is not a directory." >&2
      return 1
    fi
    if ! dir_is_empty "$venv" && ! { [[ -f $venv/pyvenv.cfg ]] && marker_matches "$venv"; }; then
      echo "Refusing to use $venv: it already holds files that this plugin's install.sh did not create." >&2
      echo "Choose an empty MAESTRAL_VENV, or remove that directory by hand first." >&2
      return 1
    fi
  fi
  printf '%s\n' "$venv"
}

# purge_target PATH
# Like resolve_venv_dir, but additionally require that the directory exists,
# is a Python virtualenv, and carries the stamp install.sh wrote for that
# exact path. Print the canonical path on success.
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
  if ! marker_matches "$venv"; then
    echo "Refusing to delete $venv: it was not created there by this plugin's install.sh." >&2
    echo "Remove the directory by hand if you are sure it is a leftover Maestral install." >&2
    return 1
  fi
  printf '%s\n' "$venv"
}

# command_link_replaceable LINK VENV
# True if install.sh may write its symlink at LINK: nothing is there, it is a
# symlink whose target no longer exists (a leftover from a removed venv), or
# it is already a symlink to the maestral command inside VENV.
command_link_replaceable() {
  local link=$1 venv=$2
  if [[ ! -e $link && ! -L $link ]]; then
    return 0
  fi
  [[ -L $link ]] || return 1
  [[ ! -e $link ]] && return 0
  [[ $(realpath -m -- "$link") == "$venv/bin/maestral" ]]
}

# cache_dir
# Print this plugin's cache directory, honouring XDG_CACHE_HOME only when it
# is an absolute path, as the XDG spec requires.
cache_dir() {
  local root="$HOME/.cache"
  [[ ${XDG_CACHE_HOME:-} == /* ]] && root=$XDG_CACHE_HOME
  printf '%s\n' "$root/omarchy-maestral"
}
