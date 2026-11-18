#!/usr/bin/env bash
# setup.sh - one entry point for the whole IDRAC7-NEW workflow.
#
#   ./setup.sh                build -> healthcheck -> offer postboot job
#   ./setup.sh --no-onboot    skip the postboot job
#   ./setup.sh --onboot       install the one-shot postboot job (no prompt)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_ONBOOT=0
SKIP_ONBOOT=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--onboot)     INSTALL_ONBOOT=1 ;;
		--no-onboot)  SKIP_ONBOOT=1 ;;
		*) echo "usage: $0 [--onboot|--no-onboot]" >&2; exit 1 ;;
	esac
	shift
done

need_root() { [[ "$(id -u)" -eq 0 ]] || { echo "run as root (sudo $0 ...)" >&2; exit 1; }; }

step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

step "1/4 build"
"$HERE/scripts/build.sh"

step "2/4 healthcheck"
"$HERE/scripts/healthcheck.sh"

step "3/4 unlock (tag write)"
"$HERE/scripts/unlock.sh" --yes --skip-idrac-reset

step "4/4 postboot automation"
if [[ "$SKIP_ONBOOT" -eq 1 ]]; then
	echo "postboot job skipped (--no-onboot)"
elif [[ "$INSTALL_ONBOOT" -eq 1 ]]; then
	"$HERE/scripts/setup-onboot.sh"
else
	read -r -p "Install the one-shot postboot license job? [y/N] " reply
	if [[ "$reply" =~ ^[Yy]$ ]]; then
		"$HERE/scripts/setup-onboot.sh"
	else
		echo "skipped - run scripts/setup-onboot.sh any time before the reboot"
	fi
fi

echo
echo "Ready to reboot. After the desktop loads, the postboot job will:"
echo "  - wait for the iDRAC to re-latch the service tag"
echo "  - import the license over WSMAN in a terminal window"
echo "  - remove itself"
echo
echo "If the import fails after ~10 minutes, power off and pull both power"
echo "cords for 30s, boot back up, and re-run scripts/postboot-check.sh."
