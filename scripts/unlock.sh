#!/usr/bin/env bash
# unlock.sh - write the license's service tag into motherboard NVRAM.
#
# Sequence:
#   1. healthcheck (fails closed)
#   2. back up the current tag
#   3. write the target tag via svctag (Dell SMI, no CentOS, no chroot)
#   4. optionally cold-reset the iDRAC
#   5. report what remains: a host POST for the iDRAC to re-latch the tag,
#      then the license import in the web UI
#
# Usage:
#   sudo ./scripts/unlock.sh [--dry-run] [--yes] [--force] [--skip-idrac-reset]
#
#   --dry-run            show the plan, write nothing
#   --yes                do not prompt (implies reboot policy from config)
#   --force              proceed even if healthcheck reports failures
#   --skip-idrac-reset   leave the management controller alone
set -euo pipefail

# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DRY_RUN=0
ASSUME_YES=0
FORCE=0
SKIP_RESET=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run)          DRY_RUN=1 ;;
		--yes|-y)           ASSUME_YES=1 ;;
		--force)            FORCE=1 ;;
		--skip-idrac-reset) SKIP_RESET=1 ;;
		-h|--help)          sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

confirm() {
	local prompt="$1" reply
	[[ "$ASSUME_YES" -eq 1 ]] && return 0
	[[ -t 0 ]] || die "no tty for confirmation - pass --yes"
	read -r -p "$prompt [y/N] " reply
	[[ "$reply" =~ ^[Yy]$ ]]
}

#
# 0. Preconditions
#
require_root
load_config
resolve_ipmitool

step "0. Preconditions"
if [[ "$FORCE" -eq 1 ]]; then
	warn "--force given: healthcheck failures will not stop the run"
	if ! "$SCRIPTS_DIR/healthcheck.sh" -q; then
		warn "healthcheck reported failures (continuing because --force)"
	fi
else
	"$SCRIPTS_DIR/healthcheck.sh" -q \
		|| die "healthcheck failed - fix the above, or pass --force"
fi

CUR_TAG="$(tagtool_get)" || die "cannot read the current service tag"
WANT_TAG="$(desired_tag)" || true
[[ -n "$WANT_TAG" ]] || die "no target tag: set NEW_SERVICE_TAG or put a tag in $LICENSE_XML"
LTAG="$(license_tag || true)"

ok "current tag : $CUR_TAG"
ok "target tag  : $WANT_TAG"
[[ -n "$LTAG" ]] && ok "license tag : $LTAG"

if [[ -n "$LTAG" && "$LTAG" != "$WANT_TAG" && "${STRICT_TAG_MATCH:-yes}" == "yes" ]]; then
	die "target tag ($WANT_TAG) does not match the license ($LTAG)
       the iDRAC rejects a license whose ServiceTag is not the host tag"
fi

#
# 1. Backup
#
step "1. Backing up the original tag"
BACKUP_FILE="$(backup_tag)" || warn "backup failed - continuing"
[[ -n "${BACKUP_FILE:-}" ]] && info "restore later with: sudo ./svctag set $(sed -n 's/^original_service_tag=//p' "$BACKUP_FILE")"

#
# 2. Write
#
step "2. Service tag write"
if [[ "$CUR_TAG" == "$WANT_TAG" ]]; then
	ok "NVRAM already reads $WANT_TAG - skipping the write"
else
	info "will write $CUR_TAG -> $WANT_TAG"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		warn "dry run: not writing"
	else
		confirm "Write $WANT_TAG to motherboard NVRAM?" || die "aborted by user"
		LIBSMBIOS_C_SO="$LIBSMBIOS_SO" "$TAGTOOL" set "$WANT_TAG" \
			|| die "firmware rejected the tag write"
		ok "NVRAM now reads $(tagtool_get)"
	fi
fi

#
# 3. iDRAC reset
#
step "3. iDRAC management controller"
if [[ "$SKIP_RESET" -eq 1 || "${IDRAC_RESET:-none}" == "none" ]]; then
	warn "skipped by request/config"
elif [[ -z "${IPMITOOL:-}" ]]; then
	warn "ipmitool not available - reset skipped"
elif [[ "$DRY_RUN" -eq 1 ]]; then
	warn "dry run: would issue 'ipmitool mc reset ${IDRAC_RESET}'"
else
	if ipmi mc reset "$IDRAC_RESET" >/dev/null 2>&1; then
		ok "iDRAC $IDRAC_RESET reset issued"
		info "waiting up to ${IDRAC_RESET_WAIT}s for the BMC to answer"
		waited=0
		until [[ "$(idrac_info || true)" == *"Device Available"* ]]; do
			(( waited >= IDRAC_RESET_WAIT )) && { warn "BMC did not answer in time"; break; }
			sleep 10; waited=$((waited + 10))
		done
		[[ "$(idrac_info || true)" == *"Device Available"* ]] && ok "BMC answering again (${waited}s)"
	else
		warn "ipmitool reset failed - continuing"
	fi
fi

#
# 4. Verify + remaining steps
#
step "4. Verification"
NVRAM_TAG="$(tagtool_get || echo '?')"
DMI_NOW="$(dmi_tag || echo '?')"
info "NVRAM (authoritative): $NVRAM_TAG"
info "DMI (boot-time cache): $DMI_NOW"

IDRAC_TAG="?"
if command -v curl >/dev/null 2>&1 && [[ -n "${IDRAC_PASS:-}" ]]; then
	idrac_pin      # a broken IDRAC_TLS_PIN must exit here, not in the subshell
	IDRAC_TAG="$(idrac_curl --max-time 10 \
		"https://$IDRAC_HOST/redfish/v1/Systems/System.Embedded.1" 2>/dev/null \
		| sed -n 's/.*"SKU":"\([^"]*\)".*/\1/p' | head -1)" || IDRAC_TAG=""
	[[ -n "$IDRAC_TAG" ]] || IDRAC_TAG="?"
	info "iDRAC view           : $IDRAC_TAG"
fi

echo
if [[ "$NVRAM_TAG" == "$WANT_TAG" ]]; then
	ok "service tag is $WANT_TAG in NVRAM"
else
	fail "NVRAM does not hold the target tag - firmware refused the write"
	exit 3
fi

if [[ "$IDRAC_TAG" != "$WANT_TAG" ]]; then
	warn "the iDRAC still reports '$IDRAC_TAG'"
	info "it latches the tag at POST, so this clears on the next host boot"
fi

cat <<EOF

$(printf '%.0s-' {1..66})
REMAINING STEPS (manual, in this order)
$(printf '%.0s-' {1..66})

1. Reboot the host so the iDRAC re-latches $WANT_TAG.
   A warm reboot usually does it. If the iDRAC still shows the old tag,
   power the box off and pull the power cords for ~30s (drop the standby
   rail) - that always clears the cached tag.

2. Import the license in the iDRAC web UI:

     https://$IDRAC_HOST/     (user: $IDRAC_USER)

     iDRAC Settings -> Licenses -> Import -> choose:
       $(basename "$LICENSE_XML")

   The file must be the XML itself, not a zip and not a .lic wrapper.
   The UI reports the result inline; a rejected license names the tag
   mismatch, which means the host has not POSTed with $WANT_TAG yet.

3. Confirm the edition flipped (Overview -> Server -> License) and that
   the Enterprise-only interfaces come up afterwards:

     ssh $IDRAC_USER@$IDRAC_HOST racadm license view

   SSH command line is refused while the box is on Express, so that
   command working at all is itself the confirmation. Redfish on iDRAC7
   firmware 2.65 exposes no license endpoint, so there is no reliable
   API-only check to script here.

Original tag backup: ${BACKUP_FILE:-<none>}
Restore at any time:  sudo ./svctag set $CUR_TAG
EOF
