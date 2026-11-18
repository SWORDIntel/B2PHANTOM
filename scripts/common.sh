#!/usr/bin/env bash
# common.sh - shared helpers for the IDRAC7 unlock scripts.
#
# Sourced, never executed. Provides: paths, config loading, logging,
# privilege checks, and small probes used by both healthcheck and unlock.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPTS_DIR")"

: "${IDRAC7_CONF:=$ROOT_DIR/config/idrac7.conf}"
TAGTOOL="$ROOT_DIR/svctag"
LIBSMBIOS_SO="$ROOT_DIR/vendor/usr/lib64/libsmbios_c.so.2"

# ---------------------------------------------------------------- logging --
if [[ -t 1 ]]; then
	C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
	C_BLU=$'\033[1;34m'; C_OFF=$'\033[0m'
else
	C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_OFF=''
fi

info() { printf '%s[info ]%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n'  "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn ]%s %s\n'  "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '%s[fail ]%s %s\n'  "$C_RED" "$C_OFF" "$*" >&2; }
die()  { fail "$*"; exit 1; }
step() { printf '\n%s== %s%s\n' "$C_BLU" "$*" "$C_OFF"; }

# ---------------------------------------------------------------- results --
CHECKS_RUN=0
CHECKS_FAILED=0
FAILED_NAMES=()

# check_pass NAME DETAIL
check_pass() {
	CHECKS_RUN=$((CHECKS_RUN + 1))
	printf '  %s[PASS]%s %-26s %s\n' "$C_GRN" "$C_OFF" "$1" "${2:-}"
}

# check_fail NAME DETAIL  (records, does not exit)
check_fail() {
	CHECKS_RUN=$((CHECKS_RUN + 1))
	CHECKS_FAILED=$((CHECKS_FAILED + 1))
	FAILED_NAMES+=("$1")
	printf '  %s[FAIL]%s %-26s %s\n' "$C_RED" "$C_OFF" "$1" "${2:-}"
}

# check_warn NAME DETAIL  (advisory, does not affect exit status)
check_warn() {
	CHECKS_RUN=$((CHECKS_RUN + 1))
	printf '  %s[WARN]%s %-26s %s\n' "$C_YEL" "$C_OFF" "$1" "${2:-}"
}

# --------------------------------------------------------------- config ----
# shellcheck disable=SC1090
load_config() {
	local f="${1:-$IDRAC7_CONF}"
	if [[ ! -f "$f" ]]; then
		die "config not found: $f
       copy a starting point with:
         cp config/idrac7.conf.example config/idrac7.conf
         chmod 600 config/idrac7.conf"
	fi

	# Defaults first so the config can override selectively. These globals are
	# consumed by the scripts that source this file, not here.
	# shellcheck disable=SC2034
	LICENSE_XML="licenses/License.xml"
	NEW_SERVICE_TAG=""
	IDRAC_HOST="169.254.0.1"
	IDRAC_USER="john"
	IDRAC_PASS=""
	IDRAC_NIC_MODE="dedicated"
	IPMITOOL=""
	IPMI_EXTRA_ARGS=""
	REBOOT_AFTER="ask"
	IDRAC_RESET="cold"
	IDRAC_RESET_WAIT="240"
	BACKUP_DIR="backups"
	LOG_DIR="logs"
	STRICT_TAG_MATCH="yes"
	# Env-overridable: an exported value wins over the default, and the
	# config file (sourced below) can still override both.
	: "${POSTBOOT_DELAY:=60}"
	: "${POSTBOOT_RETRIES:=20}"
	: "${POSTBOOT_RETRY_SLEEP:=30}"

	# shellcheck source=/dev/null
	. "$f"

	# Resolve relative paths against the project root, not the caller's cwd.
	[[ "$LICENSE_XML"  = /* ]] || LICENSE_XML="$ROOT_DIR/$LICENSE_XML"
	[[ "$BACKUP_DIR"   = /* ]] || BACKUP_DIR="$ROOT_DIR/$BACKUP_DIR"
	[[ "$LOG_DIR"      = /* ]] || LOG_DIR="$ROOT_DIR/$LOG_DIR"

	mkdir -p "$BACKUP_DIR" "$LOG_DIR"
}

# Auto-detect ipmitool unless pinned in config.
resolve_ipmitool() {
	if [[ -n "${IPMITOOL:-}" ]]; then
		[[ -x "$IPMITOOL" ]] || die "IPMITOOL=$IPMITOOL is not executable"
		return
	fi
	if IPMITOOL="$(command -v ipmitool 2>/dev/null)"; then
		return
	fi
	IPMITOOL=""
}

# Run ipmitool with the configured transport.
ipmi() {
	[[ -n "${IPMITOOL:-}" ]] || return 127
	# shellcheck disable=SC2086
	"$IPMITOOL" ${IPMI_EXTRA_ARGS:-} "$@"
}

# ------------------------------------------------------------- firmware ----
# Read the tag through the vendored libsmbios (the same code path as the
# write, so what it reports is what the setter will act on).
tagtool_get() {
	[[ -x "$TAGTOOL" ]] || die "svctag binary missing - run ./scripts/build.sh"
	LIBSMBIOS_C_SO="$LIBSMBIOS_SO" "$TAGTOOL" get 2>/dev/null
}

# DMI view of the tag: cached at boot, so it lags a fresh NVRAM write.
dmi_tag() {
	command -v dmidecode >/dev/null 2>&1 || return 1
	dmidecode -s system-serial-number 2>/dev/null
}

# Tag embedded in the license XML.
license_tag() {
	[[ -f "$LICENSE_XML" ]] || return 1
	# '#' as delimiter: the pattern itself contains ':' via the lns: prefix.
	sed -n 's#.*<lns:ServiceTag>\([^<]*\)</lns:ServiceTag>.*#\1#p' "$LICENSE_XML" \
		| head -1
}

# What the target tag should be: explicit config value, else from the XML.
desired_tag() {
	if [[ -n "${NEW_SERVICE_TAG:-}" ]]; then
		printf '%s\n' "$NEW_SERVICE_TAG"
	else
		license_tag
	fi
}

require_root() {
	[[ "$(id -u)" -eq 0 ]] || die "must run as root - prefix the command with sudo"
}

# Preserve the original tag before any write. Requires root.
# Prints ONLY the backup path on stdout; all chatter goes to stderr so
# callers can do: path="$(backup_tag)".
backup_tag() {
	local tag
	tag="$(tagtool_get || true)"
	if [[ -z "$tag" ]]; then
		warn "could not read tag for backup" >&2
		return 1
	fi
	local f
	f="$BACKUP_DIR/original-tag-$(date +%Y%m%d-%H%M%S).txt"
	{
		printf 'original_service_tag=%s\n' "$tag"
		printf 'captured=%s\n' "$(date -Is)"
		printf 'hostname=%s\n' "$(hostname)"
		printf 'dmi_tag=%s\n' "$(dmi_tag || echo unknown)"
	} > "$f"
	chmod 600 "$f"
	ok "original tag ($tag) backed up: $f" >&2
	printf '%s\n' "$f"
}

# Confirm this is a Dell 12G box with an iDRAC reachable by IPMI.
probe_platform() {
	local vendor product
	if command -v dmidecode >/dev/null 2>&1; then
		vendor="$(dmidecode -s system-manufacturer 2>/dev/null || true)"
		product="$(dmidecode -s system-product-name 2>/dev/null || true)"
	else
		# Fall back to the DMI type 1 sysfs view.
		vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
		product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
	fi
	printf '%s|%s\n' "$vendor" "$product"
}

# iDRAC firmware version + generation, via IPMI device info.
idrac_info() {
	ipmi mc info 2>/dev/null
}
