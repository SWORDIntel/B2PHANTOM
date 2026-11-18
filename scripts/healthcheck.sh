#!/usr/bin/env bash
# healthcheck.sh - verify every precondition before touching NVRAM.
#
# Read-only. Nothing here changes firmware, resets the iDRAC, or writes
# files outside logs/. Exit 0 = safe to run unlock.sh.
#
# Usage: sudo ./scripts/healthcheck.sh [-q]
#   -q   quiet: only print failures and the verdict
set -euo pipefail

# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

QUIET=0
[[ "${1:-}" == "-q" ]] && QUIET=1

say() { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
step_q() { [[ "$QUIET" -eq 1 ]] || step "$*"; }

say ""
say "B2PHANTOM - precondition check"
say "$(printf '%.0s-' {1..52})"

step_q "1. Environment"
if [[ "$(id -u)" -eq 0 ]]; then
	check_pass "root privileges"
else
	check_fail "root privileges" "re-run with sudo"
fi

if [[ -f "$IDRAC7_CONF" ]]; then
	check_pass "config file" "$IDRAC7_CONF"
	# Credentials in a world-readable file is worth flagging, not blocking.
	local_mode="$(stat -c '%a' "$IDRAC7_CONF" 2>/dev/null || echo '?')"
	if [[ "$local_mode" != "?" && "${local_mode: -2}" != "00" ]]; then
		check_warn "config permissions" "mode $local_mode - consider chmod 600"
	fi
else
	check_fail "config file" "missing $IDRAC7_CONF
       cp config/idrac7.conf.example config/idrac7.conf && chmod 600 config/idrac7.conf"
fi

load_config || true
resolve_ipmitool

step_q "2. Build artifacts"
if [[ -x "$TAGTOOL" ]]; then
	check_pass "svctag binary" "$TAGTOOL"
else
	check_fail "svctag binary" "run ./scripts/build.sh"
fi

if [[ -e "$LIBSMBIOS_SO" ]]; then
	syms="$(nm -D --defined-only "$LIBSMBIOS_SO" 2>/dev/null || true)"
	if [[ "$syms" == *sysinfo_set_service_tag* ]]; then
		check_pass "libsmbios setter" "sysinfo_set_service_tag present"
	else
		check_fail "libsmbios setter" "library lacks the setter - rebuild"
	fi
else
	check_fail "libsmbios library" "missing $LIBSMBIOS_SO - run ./scripts/build.sh"
fi

step_q "3. Hardware"
IFS='|' read -r vendor product <<<"$(probe_platform)"
if [[ "$vendor" == *Dell* ]]; then
	check_pass "Dell system" "${product:-unknown model}"
else
	check_fail "Dell system" "vendor is '${vendor:-unknown}' - this only works on Dell"
fi

if [[ "$product" =~ T([2-6])20|R([2-6])20|R([2-6])30|T([3-6])30 ]]; then
	check_pass "12G/13G platform" "$product"
else
	check_warn "platform generation" "$product - iDRAC7 path is 12G; other gens differ"
fi

# The SMI write goes through Dell's in-kernel dcdbas driver (sysfs), NOT
# through a /dev/mem write. /dev/mem is only used read-only to probe for the
# SMBIOS/token structures, and STRICT_DEVMEM still permits that low region.
DCDBAS=/sys/devices/platform/dcdbas
if [[ -d "$DCDBAS" ]]; then
	check_pass "dcdbas driver" "kernel module loaded"
	if [[ -w "$DCDBAS/smi_data" && -w "$DCDBAS/smi_request" && -w "$DCDBAS/smi_data_buf_size" ]]; then
		check_pass "dcdbas SMI nodes" "smi_data / smi_request writable"
	else
		check_fail "dcdbas SMI nodes" "sysfs nodes not writable - modprobe dcdbas?"
	fi
else
	check_fail "dcdbas driver" "missing - modprobe dcdbas"
fi

if [[ -r /dev/mem ]]; then
	check_pass "/dev/mem readable" "probe side only (SMBIOS lookup)"
else
	check_fail "/dev/mem readable" "cannot probe SMBIOS region (lockdown?)"
fi

CUR_TAG=""
if CUR_TAG="$(tagtool_get)"; then
	check_pass "tag readable" "current: $CUR_TAG"
else
	check_fail "tag readable" "cannot read service tag from firmware"
fi

DMI="$(dmi_tag || echo '')"
if [[ -n "$DMI" ]]; then
	if [[ "$DMI" == "$CUR_TAG" ]]; then
		check_pass "DMI tag in sync" "$DMI"
	else
		check_warn "DMI tag stale" "DMI '$DMI' vs NVRAM '$CUR_TAG' - clears at next boot"
	fi
fi

step_q "4. iDRAC / IPMI"
if [[ -n "$IPMITOOL" ]]; then
	check_pass "ipmitool" "$IPMITOOL"
	MC="$(idrac_info || true)"
	if [[ -n "$MC" ]]; then
		mfg="$(sed -n 's/^Manufacturer Name *: *//p' <<<"$MC" | head -1)"
		fw="$(sed -n 's/^Firmware Revision *: *//p' <<<"$MC" | head -1)"
		if [[ "$mfg" == *Dell* ]]; then
			check_pass "BMC reachable" "Dell, firmware ${fw:-unknown}"
		else
			check_fail "BMC reachable" "unexpected manufacturer '${mfg:-none}'"
		fi
	else
		check_fail "BMC reachable" "ipmitool mc info failed (driver/args?)"
	fi
else
	check_warn "ipmitool" "not installed - iDRAC reset/verify will be skipped"
fi

if command -v curl >/dev/null 2>&1 && [[ -n "${IDRAC_PASS:-}" ]]; then
	code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
		-u "$IDRAC_USER:$IDRAC_PASS" "https://$IDRAC_HOST/redfish/v1/" || echo 000)"
	case "$code" in
		200) check_pass "iDRAC web auth" "$IDRAC_USER@$IDRAC_HOST" ;;
		401) check_fail "iDRAC web auth" "credentials rejected (401)" ;;
		000) check_warn "iDRAC web auth" "no answer on https://$IDRAC_HOST" ;;
		*)   check_warn "iDRAC web auth" "HTTP $code" ;;
	esac
else
	check_warn "iDRAC web auth" "skipped (no curl or no IDRAC_PASS)"
fi

step_q "5. License"
if [[ -f "$LICENSE_XML" ]]; then
	check_pass "license file" "$LICENSE_XML"
	LTAG="$(license_tag || true)"
	if [[ -n "$LTAG" ]]; then
		check_pass "license tag" "$LTAG"
	else
		check_fail "license tag" "no <lns:ServiceTag> in the XML"
	fi
	# The signature lives in the dsig namespace, not lns:.
	if grep -q 'dsig:Signature' "$LICENSE_XML" 2>/dev/null; then
		check_pass "license signature" "signature block present"
	else
		check_fail "license signature" "XML is unsigned - iDRAC will reject it"
	fi
	if grep -qi 'Enterpri' "$LICENSE_XML" 2>/dev/null; then
		check_pass "license edition" "Enterprise features listed"
	else
		check_warn "license edition" "no 'Enterprise' string found - check the XML"
	fi
else
	check_fail "license file" "missing $LICENSE_XML"
fi

WANT="$(desired_tag || true)"
if [[ -n "$WANT" && -n "${LTAG:-}" ]]; then
	if [[ "$WANT" == "$LTAG" ]]; then
		check_pass "tag match" "target == license ($WANT)"
	else
		if [[ "${STRICT_TAG_MATCH:-yes}" == "yes" ]]; then
			check_fail "tag match" "target '$WANT' != license '$LTAG'"
		else
			check_warn "tag match" "target '$WANT' != license '$LTAG'"
		fi
	fi
fi

if [[ -n "${CUR_TAG:-}" && -n "$WANT" && "$CUR_TAG" == "$WANT" ]]; then
	check_warn "tag already applied" "NVRAM already reads $WANT - skip the write, import the license"
fi

say ""
say "$(printf '%.0s-' {1..52})"
if [[ "$CHECKS_FAILED" -eq 0 ]]; then
	ok "verdict: $CHECKS_RUN checks, 0 failures - safe to run unlock.sh"
	exit 0
fi
fail "verdict: $CHECKS_FAILED of $CHECKS_RUN checks failed: ${FAILED_NAMES[*]}"
exit 1
