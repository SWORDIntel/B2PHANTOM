#!/usr/bin/env bash
# reset-playbook.sh - factory-reset an iDRAC7 and restore it afterwards.
#
# iDRAC7 firmware 2.65 has NO remote factory-reset: no WSMAN method, no
# Redfish action, and importing the LCC factory CIM silently no-ops (the
# job queues, nothing changes - verified live on a T320). The reset itself
# needs a finger on the box:
#
#   A. Front-panel i-button: hold ~15 s until the iDRAC resets. This is the
#      12G "reset iDRAC to factory defaults" gesture.
#   B. Or pull both power cords for ~30 s (power drain). Fixes corrupted
#      GUI/state; does NOT reset users.
#
# Everything else is scriptable, and this script is the other half:
#
#   preflight   verify the recovery primitives work BEFORE the reset
#   restore     run on the HOST after the reset: users, network, services,
#               then re-import the license from anywhere with idrac7-wsman.py
#
# Recovery invariant: the host's local KCS interface reaches the BMC even
# when the BMC's network config is wiped - that is how restore works.
#
# Usage (on the host that owns the BMC):
#   sudo ./scripts/reset-playbook.sh preflight
#   sudo ./scripts/reset-playbook.sh restore
set -euo pipefail

# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need_ipmitool() {
	command -v ipmitool >/dev/null 2>&1 || die "ipmitool missing - apt install ipmitool"
	resolve_ipmitool
	ipmi mc info >/dev/null 2>&1 || die "cannot reach the BMC over local KCS"
}

# ------------------------------------------------------------- preflight ---
preflight() {
	need_ipmitool
	step "Preflight - prove the reset is recoverable BEFORE doing it"

	ipmi mc info 2>/dev/null | sed -n 's/^Firmware Revision *: */  BMC firmware: /p'
	ipmi delloem lan get 2>/dev/null | sed 's/^/  NIC selection: /' | head -4

	step "Network plan"
	ipmi lan print 1 2>/dev/null | grep -E 'IP Address Source|IP Address ' | sed 's/^/  /'
	ipmi lan print 2 2>/dev/null | grep -E 'IP Address Source|IP Address ' | sed 's/^/  /' || true

	step "Checks"
	# 'lan set' with no args prints usage listing ipsrc/ipaddr/etc when the
	# command is supported; it exits non-zero, so match the output instead.
	if ipmi lan set 1 2>&1 | grep -qi 'ipsrc'; then
		check_pass "lan set available" "can restore channel 1 IP config"
	else
		check_fail "lan set available" "cannot reconfigure BMC network via KCS"
	fi
	if ipmi delloem lan get >/dev/null 2>&1; then
		check_pass "delloem lan get" "NIC selection is readable/restorable"
	else
		check_warn "delloem lan get" "NIC selection restore unverified"
	fi

	if [[ "$CHECKS_FAILED" -gt 0 ]]; then
		die "preflight failed - do not perform the reset yet"
	fi
	ok "Preflight clean - the physical reset is safe to perform:"
	info "  A. hold the front-panel i-button ~15 s (factory defaults), or"
	info "  B. power off, pull both power cords 30 s, power on (state drain only)"
}

# --------------------------------------------------------------- restore ---
restore() {
	need_ipmitool
	load_config

	step "1. Users (KCS - works even with BMC network wiped)"
	local UIDX=2  # root is user ID 2 on iDRAC7
	if [[ -n "${IDRAC_USER:-}" ]]; then
		ipmi user set name "$UIDX" "${IDRAC_USER}" 2>/dev/null || \
			warn "could not rename user $UIDX (staying with factory name)"
	fi
	ipmi user set password "$UIDX" "${IDRAC_PASS}" \
		&& ok "user $UIDX password set to configured value" \
		|| die "failed to set BMC password"
	ipmi channel setaccess 1 "$UIDX" callin=on ipmi=on link=on privilege=4
	ok "channel 1 access granted to user $UIDX"

	step "2. Network (channel 1, LAN)"
	if [[ "${IDRAC_IP_SOURCE:-dhcp}" == "static" ]]; then
		ipmi lan set 1 ipsrc static
		ipmi lan set 1 ipaddr "${IDRAC_IP_ADDR:?IDRAC_IP_ADDR required for static}"
		ipmi lan set 1 netmask "${IDRAC_NETMASK:-255.255.255.0}"
		ipmi lan set 1 defgw ipaddr "${IDRAC_GATEWAY:-0.0.0.0}"
		ok "static IP configured: ${IDRAC_IP_ADDR}"
	else
		ipmi lan set 1 ipsrc dhcp
		ok "IP source set to DHCP (reservation should restore the address)"
	fi

	step "3. NIC selection"
	case "${IDRAC_NIC:-shared}" in
		shared)     ipmi delloem lan set shared 2>/dev/null \
				&& ok "NIC selection: shared LOM" \
				|| warn "delloem lan set shared failed - set in web UI later" ;;
		dedicated)  ipmi delloem lan set dedicated 2>/dev/null \
				&& ok "NIC selection: dedicated" \
				|| warn "delloem lan set dedicated failed" ;;
		*)          warn "IDRAC_NIC=$IDRAC_NIC not shared/dedicated - skipping" ;;
	esac

	step "4. Verify BMC answers"
	sleep 10
	ipmi mc info 2>/dev/null | sed -n 's/^Firmware Revision *: */  firmware: /p' \
		|| warn "BMC still settling - give it a minute"

	step "5. License re-import (from any machine that can reach the BMC)"
	info "  scripts/idrac7-wsman.py import --host ${IDRAC_HOST} --user ${IDRAC_USER} --password <pw> --license ${LICENSE_XML}"
	info "  (the license store survives config resets; re-run only if the edition dropped)"

	ok "restore complete - verify web UI and SSH now behave"
}

case "${1:-}" in
	preflight) preflight ;;
	restore)   restore ;;
	*)         sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
