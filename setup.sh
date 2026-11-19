#!/usr/bin/env bash
# setup.sh - B2PHANTOM interactive TUI guide.
#
# Menus: build -> healthcheck -> unlock (tag write) -> arm postboot job.
# Tracks progress in logs/setup-state so the menu shows what's done.
# Falls back to a plain text menu without a tty or whiptail.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
STATE="$ROOT/logs/setup-state"
mkdir -p "$ROOT/logs"

# shellcheck source=./scripts/common.sh
. "$HERE/scripts/common.sh"
load_config "$ROOT/config/idrac7.conf" 2>/dev/null || true

# ---------------------------------------------------------------- state ----
mark() { printf '%s=%s\n' "$1" "$2" >>"$STATE"; }
get()  { grep "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
is()   { [[ "$(get "$1")" == "done" ]]; }

mark_done() { mark "$1" done; }
mark_pend() { sed -i "/^$1=/d" "$STATE" 2>/dev/null || true; }

step_icon() { is "$1" && printf 'X' || printf ' '; }

# ---------------------------------------------------------------- helpers --
run_step() {  # run_step NAME TITLE SCRIPT
	local name="$1" title="$2" script="$3" out rc
	# $script is a fixed command line from this file; eval is safe here.
	out="$(eval "$script" 2>&1)"; rc=$?
	if [[ "$rc" -eq 0 ]]; then mark_done "$name"; else mark_pend "$name"; fi
	if [[ "$TUI" -eq 1 ]]; then
		printf '%s\n(exit %d - Enter to continue)\n' "$out" "$rc" \
			| whiptail --title "B2PHANTOM - $title" --scrollbox "$name" 20 78 0
	else
		printf '%s\n' "$out"; printf '[%s] exit=%d\n' "$name" "$rc"
	fi
	return "$rc"
}

status_text() {
	local nvram sku unit
	nvram="$(sudo -n "$ROOT/svctag" get 2>/dev/null || echo '?')"
	sku="$( { IDRAC_PASS="${IDRAC_PASS:-calvin}" \
		IDRAC_TLS_PIN="${IDRAC_TLS_PIN:-}" IDRAC_TLS_CACERT="${IDRAC_TLS_CACERT:-}" \
		IDRAC_TLS_INSECURE="${IDRAC_TLS_INSECURE:-}" \
		"$ROOT/scripts/import-license.py" --host "${IDRAC_HOST:-169.254.0.1}" \
		--user "${IDRAC_USER:-root}" \
		--license "$LICENSE_XML" --tag "$(desired_tag)" \
		--check-only 2>/dev/null || true; } \
		| grep -o 'iDRAC service tag : .*' || echo 'iDRAC service tag : ?')"
	unit="$(systemctl --user is-enabled idrac7-postboot.service 2>/dev/null || echo 'not armed')"
	printf 'NVRAM tag    : %s\n%s\npostboot job : %s\n' "$nvram" "$sku" "$unit"
}

# ---------------------------------------------------------------- steps ----
step_build()      { run_step build "build" "$ROOT/scripts/build.sh"; }
step_health()     { run_step health "healthcheck" "sudo $ROOT/scripts/healthcheck.sh"; }
step_unlock()     { run_step unlock "tag write" "sudo $ROOT/scripts/unlock.sh --yes --skip-idrac-reset"; }
step_onboot()     { run_step onboot "postboot job" "$ROOT/scripts/setup-onboot.sh"; }
step_reboot()     {
	if [[ "$TUI" -eq 1 ]]; then
		if whiptail --title "B2PHANTOM - reboot" --yesno \
			"Reboot now? The armed job handles the license import after the desktop loads." 0 0; then
			sudo systemctl reboot
		fi
	else
		read -r -p "Reboot now? [y/N] " r; [[ "$r" =~ ^[Yy]$ ]] && sudo systemctl reboot
	fi
}

# ---------------------------------------------------------------- menus ----
run_tui() {
	local choice
	while true; do
		choice="$(whiptail --title "B2PHANTOM" --menu \
			"Ring -2 doesn't need CentOS 6.         [X]=done" 15 62 8 \
			"1" "[$(step_icon build)]   Build (deps + libsmbios + svctag)" \
			"2" "[$(step_icon health)]   Healthcheck (read-only gate)" \
			"3" "[$(step_icon unlock)]   Write service tag to NVRAM" \
			"4" "[$(step_icon onboot)]   Arm one-shot postboot job" \
			"5" "    Status" \
			"6" "    Reboot now" \
			"7" "    Exit" 3>&1 1>&2 2>&3)" || choice="7"
		case "$choice" in
			1) step_build ;;
			2) step_health ;;
			3) is health || { whiptail --title "B2PHANTOM" --msgbox "Run the healthcheck first (step 2)." 8 40; continue; }
			   step_unlock ;;
			4) is unlock || { whiptail --title "B2PHANTOM" --msgbox "Run the tag write first (step 3)." 8 40; continue; }
			   step_onboot ;;
			5) status_text | whiptail --title "B2PHANTOM - status" --scrollbox "status" 14 70 0 ;;
			6) is unlock || { whiptail --title "B2PHANTOM" --msgbox "Tag write not done yet." 8 40; continue; }
			   step_reboot ;;
			7) return 0 ;;
		esac
	done
}

run_text() {
	local choice
	while true; do
		echo
		echo "B2PHANTOM - Ring -2 doesn't need CentOS 6.  [X]=done"
		echo "  [1] [$(step_icon build)]   Build"
		echo "  [2] [$(step_icon health)]   Healthcheck"
		echo "  [3] [$(step_icon unlock)]   Write service tag"
		echo "  [4] [$(step_icon onboot)]   Arm postboot job"
		echo "  [5]    Status"
		echo "  [6]    Reboot now"
		echo "  [7]    Exit"
		read -r -p "> " choice
		case "$choice" in
			1) step_build ;;
			2) step_health ;;
			3) is health || { echo "healthcheck not done yet"; continue; }; step_unlock ;;
			4) is unlock || { echo "tag write not done yet"; continue; }; step_onboot ;;
			5) status_text ;;
			6) is unlock || { echo "tag write not done yet"; continue; }; step_reboot ;;
			7) return 0 ;;
		esac
	done
}

# ---------------------------------------------------------------- main -----
TUI=0
if [[ -t 0 && -t 1 ]] && command -v whiptail >/dev/null 2>&1; then
	TUI=1
elif [[ -t 0 && -t 1 ]]; then
	echo "whiptail not installed - plain text mode (apt install whiptail for the TUI)" >&2
fi

# A gentle first-run hint, once.
if [[ ! -s "$STATE" ]]; then
	if [[ "$TUI" -eq 1 ]]; then
		whiptail --title "B2PHANTOM" --msgbox \
			"Welcome. This guide runs the unlock in order:\n\n1. Build\n2. Healthcheck\n3. Tag write\n4. Arm postboot job\n5. Reboot\n\nSteps gate on their predecessors." 12 60
	else
		echo "B2PHANTOM: run steps in order. Ctrl-C exits."
	fi
fi

if [[ "$TUI" -eq 1 ]]; then run_tui; else run_text; fi
