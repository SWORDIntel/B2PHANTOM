#!/usr/bin/env bash
# postboot-check.sh - one-shot runner after the tag-latch reboot.
#
# Waits for the desktop-then-iDRAC to settle, retries the import until the
# iDRAC has re-latched the new service tag, then fires the WSMAN license
# import and shows the result.
#
# Normally started by the one-shot user unit installed by setup-onboot.sh
# (which passes --as-service so the unit removes itself afterwards). Can
# also be run by hand.
#
# Usage:
#   scripts/postboot-check.sh [--interactive] [--as-service] [--no-uninstall]
set -euo pipefail

# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INTERACTIVE=0
AS_SERVICE=0
NO_UNINSTALL=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--interactive)  INTERACTIVE=1 ;;
		--as-service)   AS_SERVICE=1 ;;
		--no-uninstall) NO_UNINSTALL=1 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

load_config
resolve_ipmitool

# Settle time after the desktop comes up: give the iDRAC a moment to finish
# its own boot before the first probe.
: "${POSTBOOT_DELAY:=60}"
: "${POSTBOOT_RETRIES:=20}"      # x 30s sleep = up to ~10 min of patience
: "${POSTBOOT_RETRY_SLEEP:=30}"

IMPORTER="$SCRIPTS_DIR/import-license.py"
UNIT="idrac7-postboot.service"
UNIT_FILE="$HOME/.config/systemd/user/$UNIT"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/postboot-$TS.log"
exec >>"$LOG" 2>&1

log()  { printf '[postboot %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
# stdout is already the log file (exec above); no tee needed.
result() { printf '\n>>> %s\n' "$*"; }

# A terminal was requested; make sure we have DISPLAY/XAUTHORITY even if the
# user session did not export them into systemd.
if [[ "$INTERACTIVE" -eq 1 ]]; then
	: "${DISPLAY:=:0}"
	export DISPLAY
	: "${XAUTHORITY:=$HOME/.Xauthority}"
	export XAUTHORITY
fi

log "starting (delay ${POSTBOOT_DELAY}s, up to $((POSTBOOT_RETRIES * POSTBOOT_RETRY_SLEEP))s of patience)"
sleep "$POSTBOOT_DELAY"

TAG="$(desired_tag)" || die "no target tag configured"
log "target tag: $TAG"

RC=2
ATTEMPT=0
while [[ "$ATTEMPT" -lt "$POSTBOOT_RETRIES" ]]; do
	ATTEMPT=$((ATTEMPT + 1))
	log "attempt $ATTEMPT/$POSTBOOT_RETRIES"
	set +e
	"$IMPORTER" --host "$IDRAC_HOST" --user "$IDRAC_USER" --password "$IDRAC_PASS" \
		--license "$LICENSE_XML" --tag "$TAG"
	RC=$?
	set -e
	if [[ "$RC" -eq 0 ]]; then
		result "LICENSE IMPORTED - iDRAC7 should now be Enterprise"
		break
	fi
	log "rc=$RC (tag not latched yet or iDRAC busy) - sleeping ${POSTBOOT_RETRY_SLEEP}s"
	sleep "$POSTBOOT_RETRY_SLEEP"
done

if [[ "$RC" -ne 0 ]]; then
	result "IMPORT NOT COMPLETE - the iDRAC has not accepted the license."
	result "Power off the box, pull both power cords for ~30s (drop the standby"
	result "rail), power back on, then re-run:"
	result "  $IMPORTER --host $IDRAC_HOST --user $IDRAC_USER --license $LICENSE_XML --tag $TAG"
fi

# One-time unit: remove itself regardless of outcome so the next boot is clean.
if [[ "$AS_SERVICE" -eq 1 && "$NO_UNINSTALL" -eq 0 ]]; then
	if systemctl --user disable "$UNIT" >/dev/null 2>&1; then
		log "disabled $UNIT (one-shot complete)"
	fi
	rm -f "$UNIT_FILE" && log "removed $UNIT_FILE"
fi

log "full log: $LOG"

if [[ "$INTERACTIVE" -eq 1 ]]; then
	# Keep the terminal open so the result is actually seen.
	printf '\nThis window closes in 30s or on Enter.\n'
	read -r -t 30 _ || true
fi

# Reflect the outcome in the exit status (systemd records it on the unit).
exit $(( RC == 0 ? 0 : 1 ))
