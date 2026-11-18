#!/usr/bin/env bash
# setup-onboot.sh - install a ONE-TIME postboot job for the license import.
#
# After the tag-latch reboot, this job waits for your desktop session
# (~60s), then pops a terminal that:
#   1. waits for the iDRAC to re-latch the new service tag (Redfish SKU),
#   2. imports licenses/License.xml via WSMAN once the tag matches,
#   3. shows the result and removes itself (next boot is clean).
#
# Usage:
#   scripts/setup-onboot.sh            install + enable (fires next boot)
#   scripts/setup-onboot.sh --linger   also enable user lingering (headless boots)
#   scripts/setup-onboot.sh --remove   remove the job
set -euo pipefail

# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

UNIT="idrac7-postboot.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/$UNIT"
POSTBOOT="$(cd "$SCRIPTS_DIR" && pwd)/postboot-check.sh"

WANT_LINGER=0
WANT_REMOVE=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--linger) WANT_LINGER=1 ;;
		--remove) WANT_REMOVE=1 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

if [[ "$WANT_REMOVE" -eq 1 ]]; then
	systemctl --user disable "$UNIT" >/dev/null 2>&1 || true
	rm -f "$UNIT_FILE"
	ok "removed $UNIT_FILE"
	exit 0
fi

load_config

# Preconditions: a user session systemd, a terminal emulator for the popup,
# and the import script.
# A user manager in any non-offline state (running/degraded/starting)
# means systemd --user is alive. is-system-running exits 1 on 'degraded',
# which is still a usable session - only 'offline' means no manager.
USER_STATE="$(systemctl --user is-system-running 2>/dev/null || true)"
[[ -n "$USER_STATE" && "$USER_STATE" != "offline" ]] \
	|| die "systemd --user is not running (no desktop session?)"

TERM_BIN="$(command -v xterm || command -v konsole || true)"
[[ -n "$TERM_BIN" ]] || die "no terminal emulator found (xterm/konsole)"

[[ -x "$POSTBOOT" ]] || die "missing $POSTBOOT"
[[ -f "$SCRIPTS_DIR/import-license.py" ]] || die "missing import-license.py"
[[ -f "$LICENSE_XML" ]] || die "missing license: $LICENSE_XML"

mkdir -p "$UNIT_DIR"

# The unit starts at the graphical session, waits POSTBOOT_DELAY seconds,
# then runs the checker inside a visible terminal. Type=oneshot +
# ExecStart=xterm means the terminal IS the job's foreground process.
cat >"$UNIT_FILE" <<EOF
[Unit]
Description=iDRAC7 license postboot import (one-shot)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=$TERM_BIN -T "iDRAC7 Postboot License" -e $POSTBOOT --interactive --as-service
TimeoutSec=1200

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload
systemctl --user enable "$UNIT" >/dev/null 2>&1 \
	|| die "failed to enable $UNIT"

if [[ "$WANT_LINGER" -eq 1 ]]; then
	if command -v loginctl >/dev/null 2>&1; then
		loginctl enable-linger "$(id -un)"
		ok "user lingering enabled (job survives headless boots)"
	else
		warn "loginctl not found - lingering not enabled"
	fi
else
	warn "no --linger: the job fires only when you log into the desktop"
fi

ok "installed and enabled: $UNIT_FILE"
ok "fires on the NEXT boot, ~${POSTBOOT_DELAY:-60}s after the desktop loads, in a $TERM_BIN window"
ok "the unit disables and deletes itself when it finishes (one-shot)"
info "remove early with: $0 --remove"
