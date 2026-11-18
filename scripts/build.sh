#!/usr/bin/env bash
# build.sh - install build deps if needed, fetch Dell libsmbios, compile svctag.
#
# Nothing is installed system-wide except the build dependencies themselves
# (gcc, cpio, ...). The libsmbios RPMs are extracted into vendor/, never
# installed: no legacy CentOS userland is introduced, and the Dell library
# never lands in /usr/lib.
#
# Usage:
#   ./scripts/build.sh                # auto-install missing deps
#   ./scripts/build.sh --no-deps      # never touch the package manager
#   ./scripts/build.sh --check-deps   # report what is missing, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
VENDOR="$ROOT/vendor"
CACHE="$VENDOR/.rpm-cache"
SRC="$ROOT/src"
BIN="$ROOT/svctag"

REPO_BASE="https://linux.dell.com/repo/hardware/Linux_Repository_14.04.00/platform_independent/rh60_64/firmware-tools"
VER="2.2.27-4.12.1.el6"

PKGS=(
	"libsmbios-${VER}.x86_64.rpm"
	"smbios-utils-bin-${VER}.x86_64.rpm"
)

NO_DEPS=0
CHECK_DEPS=0
for arg in "$@"; do
	case "$arg" in
		--no-deps)    NO_DEPS=1 ;;
		--check-deps) CHECK_DEPS=1 ;;
		-h|--help)    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)            printf 'unknown argument: %s\n' "$arg" >&2; exit 1 ;;
	esac
done

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- deps ------
# command name -> Debian package that provides it
DEP_PKGS=(
	"gcc:gcc"
	"curl:curl"
	"cpio:cpio"
	"rpm2cpio:rpm2cpio"
	"nm:binutils"
)
# Optional: needed by healthcheck/unlock, not by the build itself
OPT_PKGS=(
	"ipmitool:ipmitool"
	"dmidecode:dmidecode"
	"sudo:sudo"
)

missing_cmds() {
	local pair cmd
	for pair in "$@"; do
		cmd="${pair%%:*}"
		command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
	done
}

install_deps() {
	local -a cmds pkgs
	mapfile -t cmds < <(missing_cmds "${DEP_PKGS[@]}")
	if [[ "${#cmds[@]}" -eq 0 ]]; then
		return 0
	fi

	local pair cmd
	pkgs=()
	for pair in "${DEP_PKGS[@]}"; do
		cmd="${pair%%:*}"
		for m in "${cmds[@]}"; do
			[[ "$m" == "$cmd" ]] && pkgs+=("${pair##*:}")
		done
	done

	warn "missing build deps: ${cmds[*]}"
	warn "packages needed   : ${pkgs[*]}"

	if [[ "$CHECK_DEPS" -eq 1 ]]; then
		return 0
	fi
	if [[ "$NO_DEPS" -eq 1 ]]; then
		die "deps missing and --no-deps was given; install: ${pkgs[*]}"
	fi

	command -v apt-get >/dev/null 2>&1 \
		|| die "not a Debian-family system; install manually: ${pkgs[*]}"

	local -a SUDO=()
	[[ "$(id -u)" -eq 0 ]] || SUDO=(sudo)

	log "installing: ${pkgs[*]}"
	"${SUDO[@]}" apt-get update -qq
	DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y -qq "${pkgs[@]}" \
		|| die "package install failed"

	mapfile -t cmds < <(missing_cmds "${DEP_PKGS[@]}")
	[[ "${#cmds[@]}" -eq 0 ]] || die "still missing after install: ${cmds[*]}"
	log "build deps satisfied"
}

install_deps

if [[ "$CHECK_DEPS" -eq 1 ]]; then
	opt_missing="$(missing_cmds "${OPT_PKGS[@]}" | tr '\n' ' ')"
	if [[ -n "${opt_missing// /}" ]]; then
		log "build deps OK; optional missing: $opt_missing"
	else
		log "build deps OK; optional deps OK"
	fi
	exit 0
fi

# Report optional gaps without failing the build.
opt_missing="$(missing_cmds "${OPT_PKGS[@]}" | tr '\n' ' ')"
[[ -n "${opt_missing// /}" ]] && warn "optional tools missing: $opt_missing"

# --------------------------------------------------------------- fetch -----
mkdir -p "$VENDOR" "$CACHE"

for pkg in "${PKGS[@]}"; do
	if [[ -s "$CACHE/$pkg" ]]; then
		log "cached: $pkg"
		continue
	fi
	log "fetching $pkg"
	curl -fsSL --retry 3 --retry-delay 2 --max-time 180 \
		-o "$CACHE/$pkg.part" "$REPO_BASE/$pkg" \
		|| die "download failed: $REPO_BASE/$pkg"
	mv "$CACHE/$pkg.part" "$CACHE/$pkg"
done

log "extracting packages into vendor/"
find "$VENDOR" -mindepth 1 -maxdepth 1 ! -name '.rpm-cache' -exec rm -rf {} +

for pkg in "${PKGS[@]}"; do
	rpm2cpio "$CACHE/$pkg" | ( cd "$VENDOR" && cpio -idm --quiet )
done

LIB="$VENDOR/usr/lib64/libsmbios_c.so.2"
[[ -e "$LIB" ]] || die "extraction did not produce $LIB"

# ----------------------------------------------------------- symbol check --
# The whole point of this project: newer libsmbios builds ship without the
# setter, and a library that only reads tags cannot unlock anything.
syms="$(nm -D --defined-only "$LIB" 2>/dev/null || true)"
if [[ "$syms" == *sysinfo_set_service_tag* && "$syms" == *sysinfo_get_service_tag* ]]; then
	log "symbol check: get + set service tag present"
else
	die "libsmbios_c.so.2 lacks the setter - wrong build, refusing to continue"
fi

# ------------------------------------------------------------- compile -----
log "compiling svctag"
gcc -O2 -Wall -Wextra -o "$BIN" "$SRC/svctag.c" -ldl \
	|| die "compilation failed"
chmod 0755 "$BIN"

# -------------------------------------------------------------- smoke ------
log "smoke test (read-only)"
if out="$("$BIN" get 2>&1)"; then
	log "current service tag: $out"
elif [[ "$(id -u)" -ne 0 ]]; then
	warn "tag read needs root - rerun with sudo to verify: sudo $BIN check"
else
	warn "tag read failed: $out"
	warn "expected if this is not a Dell bare-metal host"
fi

log "done"
log "  binary : $BIN"
log "  library: $LIB"
log "next     : sudo ./scripts/healthcheck.sh"
