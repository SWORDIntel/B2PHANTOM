#!/usr/bin/env bash
# postboot-terminal.sh - wait for a usable X display, then pop the postboot
# terminal. Fixes the race where graphical-session.target fires before the
# display exists (observed live: xterm died with "DISPLAY is not set").
#
# If no display appears within 10 minutes, the check runs headless instead -
# the import still happens, results land in logs/, nothing is lost.
set -u

POSTBOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postboot-check.sh"
DEADLINE=$(( $(date +%s) + 600 ))

while :; do
	if [[ -n "${DISPLAY:-}" ]] && [[ -S "/tmp/.X11-unix/${DISPLAY#:}" ]]; then
		break
	fi
	sock="$(ls /tmp/.X11-unix/X* 2>/dev/null | head -1)"
	if [[ -n "$sock" ]]; then
		export DISPLAY=":${sock##*X}"
		break
	fi
	if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
		echo "postboot-terminal: no display after 10 min - running headless" >&2
		exec "$POSTBOOT" --as-service
	fi
	sleep 5
done

export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
exec xterm -T "B2PHANTOM Postboot" -e "$POSTBOOT" --interactive --as-service
