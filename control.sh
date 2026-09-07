#!/bin/bash
# Daemon control for the widget: start | pause | resume.
#
# When Maestral's systemd user unit is enabled (link.sh enables it), the daemon
# is started through systemd so it outlives the shell process that asked for
# it. Otherwise it falls back to `maestral start`, which spawns the daemon as a
# child of the caller's session scope.

set -uo pipefail

CONFIG_NAME="${MAESTRAL_CONFIG_NAME:-maestral}"
UNIT="maestral-daemon@${CONFIG_NAME}.service"

start_daemon() {
  if systemctl --user is-enabled --quiet "$UNIT" 2>/dev/null; then
    systemctl --user start "$UNIT"
  else
    maestral start --config-name "$CONFIG_NAME"
  fi
}

case "${1:-}" in
  start) start_daemon ;;
  pause) maestral pause --config-name "$CONFIG_NAME" ;;
  resume) maestral resume --config-name "$CONFIG_NAME" ;;
  *) echo "usage: control.sh start|pause|resume" >&2; exit 2 ;;
esac
