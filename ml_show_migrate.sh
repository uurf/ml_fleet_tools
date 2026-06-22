#!/usr/bin/env bash
# ============================================================
# ml_show_migrate.sh — migrate ONE USB-connected device between shows
# (e.g. KAGAMI/RED → KAGAMI_BLUE). Tin Drum / Magic Leap 2.
#
#   ./ml_show_migrate.sh                 # prompt from/to, USB device
#   ./ml_show_migrate.sh --to KAGAMI_BLUE
#   ./ml_show_migrate.sh --from KAGAMI --to KAGAMI_BLUE -d <usb-serial>
#   ./ml_show_migrate.sh --dry-run --to KAGAMI_BLUE   # show plan, change nothing
#
# USB only — migration deletes/installs apps and switches the device's wifi;
# doing it over the device's own wifi would strand it. Sequence (fail-safe):
#   1. deploy the DESIRED show's builds over USB (app + kiosk, set home)
#   2. CONFIRM over USB (desired app present + kiosk has desired suffix)
#      — abort here, BEFORE the destructive wifi switch / inventory move, if
#        builds were wrong; the device is recoverable by re-running.
#   3. provision over USB → scrub the OTHER show's app (DESIRED's
#      SHOW_REMOVE_PACKAGES) + settings + join DESIRED wifi + enable wifi ADB
#      (this is when the device leaves USB / the current network)
#   4. move the device's serial row from inventory/<FROM>.csv to
#      inventory/<TO>.csv (device# travels unchanged)
# Final verification is on the DESIRED network: switch the laptop's wifi and
# run ml_status (the device has left the current network by design).
# ============================================================

set -euo pipefail

# bash 5+ required (macOS default 3.2 lacks mapfile et al.) — hard-stop early
source "$(dirname "${BASH_SOURCE[0]}")/lib/require_bash5.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"; CROSS="${RED}✗${RESET}"
KIOSK_PKG="com.tindrum.kiosk"

DRY_RUN=false
FROM=""; TO=""; USB_SERIAL="${ANDROID_SERIAL:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --from)    FROM="$2"; shift ;;
    --to)      TO="$2"; shift ;;
    -d)        USB_SERIAL="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo -e "${RED}Unknown arg: $1${RESET}"; exit 1 ;;
  esac
  shift
done

# ── helpers ──────────────────────────────────────────────────
# Resolve a specific show's config var (isolated subshell so it doesn't disturb
# this script's environment).
show_var() ( ML_SHOW="$1"; source "$SCRIPT_DIR/lib/show_config.sh" >/dev/null 2>&1; printf '%s' "${!2:-}" )

available_shows() {
  local f b
  for f in "$SCRIPT_DIR"/shows/*.conf; do
    [[ -e "$f" ]] || continue
    b="$(basename "$f" .conf)"
    [[ "$b" == "EXAMPLE" ]] && continue
    echo "$b"
  done
}

pick_show() {  # $1 = prompt label; echoes chosen show id (to stdout); prompts on stderr
  local label="$1" shows=() i=1 choice
  while IFS= read -r s; do shows+=("$s"); done < <(available_shows)
  echo "" >&2
  echo -e "  ${BOLD}$label${RESET}" >&2
  for s in "${shows[@]}"; do echo -e "    $i) $s" >&2; ((i++)); done
  read -rp "  # " choice </dev/tty
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#shows[@]} )) || { echo -e "${RED}Invalid choice${RESET}" >&2; exit 1; }
  echo "${shows[$((choice-1))]}"
}

# run-or-echo (dry-run aware) for the destructive sub-script calls
run() {
  if $DRY_RUN; then echo -e "  ${DIM}[dry-run] $*${RESET}"; return 0; fi
  "$@"
}

# ── USB device ───────────────────────────────────────────────
if [[ -z "$USB_SERIAL" ]]; then
  # auto-pick the single USB device (exclude wifi ip:5555 entries)
  mapfile -t _usb < <(adb devices | grep -v "List of" | grep "device$" | awk '{print $1}' | grep -v ':5555' || true)
  if [[ ${#_usb[@]} -eq 0 ]]; then
    echo -e "${RED}No USB device found. Connect via USB-C and tap 'Allow USB debugging'.${RESET}"; exit 1
  elif [[ ${#_usb[@]} -gt 1 ]]; then
    echo -e "${YELLOW}Multiple USB devices — pick one with -d <serial>:${RESET}"; printf '  %s\n' "${_usb[@]}"; exit 1
  fi
  USB_SERIAL="${_usb[0]}"
fi
HW_SERIAL=$(adb -s "$USB_SERIAL" shell getprop ro.serialno 2>/dev/null | tr -d '\r' || true)
[[ -z "$HW_SERIAL" ]] && { echo -e "${RED}Can't read serial from $USB_SERIAL (authorized? 'adb devices' shows 'device'?).${RESET}"; exit 1; }

# ── from / to shows ──────────────────────────────────────────
mapfile -t ALL_SHOWS < <(available_shows)
[[ -z "$FROM" ]] && FROM=$(pick_show "Current show (migrate FROM):")
if [[ -z "$TO" ]]; then
  if [[ ${#ALL_SHOWS[@]} -eq 2 ]]; then
    for s in "${ALL_SHOWS[@]}"; do [[ "$s" != "$FROM" ]] && TO="$s"; done   # imply the other
    echo -e "  ${DIM}Only two shows configured — migrating to: ${RESET}${BOLD}$TO${RESET}"
  else
    TO=$(pick_show "Desired show (migrate TO):")
  fi
fi
[[ "$FROM" == "$TO" ]] && { echo -e "${RED}FROM and TO are the same ($FROM).${RESET}"; exit 1; }
printf '%s\n' "${ALL_SHOWS[@]}" | grep -qxF "$FROM" || { echo -e "${RED}Unknown show: $FROM${RESET}"; exit 1; }
printf '%s\n' "${ALL_SHOWS[@]}" | grep -qxF "$TO"   || { echo -e "${RED}Unknown show: $TO${RESET}"; exit 1; }

# ── resolve DESIRED config ───────────────────────────────────
TO_PKG=$(show_var "$TO" SHOW_PACKAGE)
TO_SUFFIX=$(show_var "$TO" SHOW_KIOSK_SUFFIX)
TO_SSID=$(show_var "$TO" SHOW_SSID)
[[ -z "$TO_PKG" ]] && { echo -e "${RED}Could not resolve $TO SHOW_PACKAGE.${RESET}"; exit 1; }

# device# for this serial (carry it across) — prefer FROM's inventory
FROM_INV="$SCRIPT_DIR/inventory/$FROM.csv"
TO_INV="$SCRIPT_DIR/inventory/$TO.csv"
DEVNUM=""
[[ -f "$FROM_INV" ]] && DEVNUM=$(awk -F, -v s="$HW_SERIAL" '{sub(/\r$/,"")} toupper($2)==toupper(s){print $1; exit}' "$FROM_INV")

# ── builds pre-flight ────────────────────────────────────────
mapfile -t BUILDS < <(find "$SCRIPT_DIR/builds" -maxdepth 1 -name '*.apk' 2>/dev/null | sort || true)
if [[ ${#BUILDS[@]} -eq 0 ]]; then
  echo -e "${RED}No APKs in builds/ — load the ${TO} show app + kiosk first.${RESET}"; exit 1
fi

# ── plan ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   ML2 Show Migration                         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo -e "  Device:     ${CYAN}$HW_SERIAL${RESET}${DEVNUM:+  ${DIM}(device #$DEVNUM)${RESET}}  ${DIM}[USB $USB_SERIAL]${RESET}"
echo -e "  Migrate:    ${BOLD}$FROM${RESET}  →  ${BOLD}$TO${RESET}"
echo -e "  Will:       install $TO builds (app $TO_PKG + kiosk *$TO_SUFFIX), scrub $FROM app, join wifi ${CYAN}$TO_SSID${RESET}"
echo -e "  builds/:"
printf '    %s\n' "${BUILDS[@]##*/}"
echo -e "  Inventory:  move $HW_SERIAL  $(basename "$FROM_INV") → $(basename "$TO_INV")"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN — no changes will be made${RESET}"
echo ""
echo -e "  ${YELLOW}Confirm builds/ above are the ${TO} show's app + kiosk.${RESET}"
if ! $DRY_RUN; then
  read -rp "  Proceed with migration? [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || { echo -e "  ${DIM}Aborted — nothing changed.${RESET}"; exit 0; }
fi

# common env for sub-scripts: target the USB device, pre-confirm the show,
# bypass the update gate when set in the parent (dev testing).
SUBENV=(ML_SHOW="$TO" ML_SHOW_CONFIRMED=1 ANDROID_SERIAL="$USB_SERIAL")
[[ -n "${ML_DEV_TEST:-}" ]] && SUBENV+=(ML_DEV_TEST="$ML_DEV_TEST")

# ── 1. deploy desired builds over USB ────────────────────────
echo ""
echo -e "${BOLD}── 1/4  Deploy $TO builds (USB) ─────────────────${RESET}"
run env "${SUBENV[@]}" bash "$SCRIPT_DIR/ml_deploy.sh" --all

# ── 2. confirm over USB BEFORE the destructive switch ────────
echo ""
echo -e "${BOLD}── 2/4  Confirm install (USB) ───────────────────${RESET}"
if $DRY_RUN; then
  echo -e "  ${DIM}[dry-run] would verify $TO_PKG installed + kiosk versionName ends with '$TO_SUFFIX'${RESET}"
else
  pkgs=$(adb -s "$USB_SERIAL" shell pm list packages 2>/dev/null | tr -d '\r' || true)
  if ! grep -q "$TO_PKG" <<< "$pkgs"; then
    echo -e "  ${CROSS} ${RED}$TO_PKG NOT installed after deploy — wrong builds/ for $TO? Aborting before wifi switch.${RESET}"
    echo -e "  ${DIM}Device keeps USB/current network; fix builds/ and re-run.${RESET}"; exit 1
  fi
  kver=$(adb -s "$USB_SERIAL" shell dumpsys package "$KIOSK_PKG" 2>/dev/null | grep versionName | head -1 | sed 's/.*versionName=//' | tr -d '\r' || true)
  if [[ -n "$TO_SUFFIX" && "$kver" != *"$TO_SUFFIX" ]]; then
    echo -e "  ${CROSS} ${RED}kiosk versionName '$kver' does not end with '$TO_SUFFIX' — wrong kiosk for $TO. Aborting before wifi switch.${RESET}"; exit 1
  fi
  echo -e "  ${TICK} $TO_PKG installed; kiosk '$kver' matches *$TO_SUFFIX"
fi

# ── 3. provision: scrub old app + settings + join desired wifi
echo ""
echo -e "${BOLD}── 3/4  Provision to $TO (scrub $FROM, switch wifi) ──${RESET}"
echo -e "  ${DIM}Device leaves USB / the current network at this step.${RESET}"
run env "${SUBENV[@]}" bash "$SCRIPT_DIR/ml_provision.sh"

# ── 4. move inventory row (device# travels) ──────────────────
echo ""
echo -e "${BOLD}── 4/4  Move inventory row ──────────────────────${RESET}"
move_inventory() {
  mkdir -p "$SCRIPT_DIR/inventory"
  # remove from FROM
  if [[ -f "$FROM_INV" ]]; then
    local tmp; tmp=$(mktemp)
    awk -F, -v s="$HW_SERIAL" '{line=$0; sub(/\r$/,""); if (toupper($2)==toupper(s)) next; print line}' "$FROM_INV" > "$tmp" && mv "$tmp" "$FROM_INV"
  fi
  # add to TO (header if new; skip if already present)
  [[ -f "$TO_INV" ]] || echo "Device,Serial" > "$TO_INV"
  if awk -F, -v s="$HW_SERIAL" '{sub(/\r$/,"")} toupper($2)==toupper(s){f=1} END{exit !f}' "$TO_INV"; then
    echo -e "  ${DIM}$HW_SERIAL already in $(basename "$TO_INV")${RESET}"
  else
    printf '%s,%s\n' "$DEVNUM" "$HW_SERIAL" >> "$TO_INV"
  fi
}
if $DRY_RUN; then
  echo -e "  ${DIM}[dry-run] would remove $HW_SERIAL from $(basename "$FROM_INV") and add '${DEVNUM},$HW_SERIAL' to $(basename "$TO_INV")${RESET}"
else
  move_inventory
  echo -e "  ${TICK} $HW_SERIAL → $(basename "$TO_INV")${DEVNUM:+ (device #$DEVNUM)}"
  [[ -z "$DEVNUM" ]] && echo -e "  ${YELLOW}⚠ no device# on record for $HW_SERIAL — assign one in $(basename "$TO_INV").${RESET}"
fi

# ── done ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Migration complete: $FROM → $TO${RESET}"
echo -e "  The device is now on ${CYAN}$TO_SSID${RESET} wifi and has left this network."
echo -e "  ${BOLD}To verify:${RESET} switch this laptop's wifi to ${CYAN}$TO_SSID${RESET}, then:"
echo -e "    ${DIM}ML_SHOW=$TO ./utilities/ml_scan.sh --append --yes && ML_SHOW=$TO ./ml_status.sh${RESET}"
echo -e "  Confirm the device shows ${BOLD}all-OK${RESET} (app $TO_PKG, kiosk *$TO_SUFFIX)."
echo ""
