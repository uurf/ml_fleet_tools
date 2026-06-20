#!/usr/bin/env bash
# ============================================================
# Magic Leap 2 Device Provisioning — KAGAMI / Tin Drum
# Target OS: 1.4.1 (B3E.230928.10-R.098)
#
# Runs automatically after ml_os_flash.sh, or standalone:
#   ./ml_provision.sh                    # full provision (USB device)
#   ./ml_provision.sh -d <ip>            # target a specific device by IP
#   ./ml_provision.sh --check            # read & report current state (single device)
#   ./ml_provision.sh --discover         # just print serial + MAC
#   ./ml_provision.sh --fleet            # apply ADB-settable settings to all devices.txt devices
#   ./ml_provision.sh --fleet --check    # check settings across entire fleet
#
# NOTE ON ML2-SPECIFIC SETTINGS:
#   Global Dimming, Segmented Dimming, Display Override, Display Modes,
#   and Compute Pack Standby are controlled by Magic Leap system services,
#   NOT standard Android settings. They cannot be set via "settings put".
#   The script uses ml-specific service calls where known, and flags the
#   ones that still require a one-time manual step in the headset UI.
#   These manual steps are printed as a checklist at the end.
# ============================================================

set -euo pipefail

# bash 5+ required (macOS default 3.2 lacks mapfile et al.) — hard-stop early
source "$(dirname "${BASH_SOURCE[0]}")/lib/require_bash5.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
MANUAL="${YELLOW}⊙${RESET}"
SKIP="${DIM}–${RESET}"


# ---- Google Sheets update ------------------------------------------
# Per-show: URL comes from SHOW_SHEETS_URL in shows/<id>.conf. Blank →
# no-op (used for shows without a tracking workbook configured yet).
update_sheet() {
  [[ -z "${SHOW_SHEETS_URL:-}" ]] && return 0
  local action="$1" serial="$2" device_num="${3:-}" case_num="${4:-}" wifi_ok="${5:-false}" operator_initials="${6:-}"
  python3 -c "
import urllib.request, json, sys
url = '$SHOW_SHEETS_URL'
data = json.dumps({'action':'ACTION','serial':'SERIAL','device_number':'DEVNUM','case_number':'CASENUM','wifi_connected':'WIFIOK','operator_initials':'INITIALS'}).encode()
data = data.replace(b'ACTION', '$action'.encode()).replace(b'SERIAL', '$serial'.encode()).replace(b'DEVNUM', '$device_num'.encode()).replace(b'CASENUM', '$case_num'.encode()).replace(b'WIFIOK', '$wifi_ok'.encode()).replace(b'INITIALS', '$operator_initials'.encode())
req = urllib.request.Request(url, data=data, headers={'Content-Type':'application/json'})
try:
  urllib.request.urlopen(req, timeout=10)
except Exception as e:
  sys.stderr.write(str(e))
" 2>/dev/null || true
}


# ---- Check for toolkit updates -------------------------------------
# Requires network — silently skips if offline.
# Hard stops if local repo is behind origin/main.
check_for_updates() {
  if [[ -n "${ML_DEV_TEST:-}" ]]; then
    echo -e "${YELLOW}⚠ ML_DEV_TEST set — update gate bypassed (dev testing only).${RESET}" >&2
    return 0
  fi
  # Skip if called from ml_os_flash.sh — it already checked
  [[ -n "${ANDROID_SERIAL:-}" ]] && return 0
  if ! git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null; then
    echo -e "${YELLOW}⚠ No network — skipping update check.${RESET}"
    return 0
  fi

  local local_sha origin_sha
  local_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
  origin_sha=$(git -C "$SCRIPT_DIR" rev-parse origin/main 2>/dev/null)

  if [[ "$local_sha" != "$origin_sha" ]]; then
    echo ""
    echo -e "${RED}┌─────────────────────────────────────────────────┐${RESET}"
    echo -e "${RED}│  Toolkit is out of date — please update first   │${RESET}"
    echo -e "${RED}└─────────────────────────────────────────────────┘${RESET}"
    echo ""
    echo -e "  Run: ${CYAN}./update.sh${RESET}"
    echo ""
    exit 1
  fi
}
TOOLKIT_VERSION=$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "unversioned")
check_for_updates

# ============================================================
# CONFIG
# ============================================================

TARGET_BUILD="B3E.230928.10-R.098"

# WIFI_* and APP_PACKAGE come from the active show config —
# assigned just below, after arg parsing (see lib/show_config.sh).
APP_PERMISSIONS=(
  "android.permission.CAMERA"
  "android.permission.RECORD_AUDIO"
  "android.permission.READ_EXTERNAL_STORAGE"
  "android.permission.WRITE_EXTERNAL_STORAGE"
  "android.permission.ACCESS_FINE_LOCATION"
  "android.permission.ACCESS_COARSE_LOCATION"
)

# Apps to remove — exact package names.
# Deliberately empty. com.tindrum.kiosk is the toolkit's OWN
# home/launcher app — installed by ml_deploy.sh and set as HOME, not
# a stale foreign-show app. Listing it here uninstalled the kiosk on
# every non---check provision, including standalone fleet drift
# remediation (which has no deploy after it to reinstall it). In the
# flash→provision→deploy chain the device is freshly wiped so there
# is nothing to remove anyway, and deploy installs the kiosk after.
# Foreign-show + obsolete apps are scrubbed via the active show's
# SHOW_REMOVE_PACKAGES (exact package ids — e.g. com.tindrum.anark,
# com.tindrum.medusa, com.tindrum.thelife, the other show's app, and the
# obsolete com.tindrum.kagamu), seeded into REMOVE_PACKAGES below.
# Do NOT re-add the kiosk here.
REMOVE_PACKAGES=()

# Directories to delete from device storage. Foreign-show data only —
# NOT com.tindrum.kiosk's data dir, for the same reason as above: a
# settings pass must not wipe an intentionally-deployed kiosk's state.
REMOVE_DIRS=(
  "/sdcard/AnArk"
)

# ============================================================

MODE="full"
CHAIN_DEPLOY=false
FLEET=false
FLEET_WORKER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)        MODE="check" ;;
    --discover)     MODE="discover" ;;
    --deploy)       CHAIN_DEPLOY=true ;;
    --fleet)        FLEET=true ;;
    --fleet-worker) FLEET_WORKER=true ;;
    -d)             ANDROID_SERIAL="${2}:5555"; shift ;;
    --help|-h)
      echo "Usage: ./ml_provision.sh [-d <ip>] [--check|--discover|--deploy|--fleet [--check]]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

# ---- Resolve active show -------------------------------------------
# Sourced after arg parsing so FLEET_WORKER is known (suppresses the
# legacy-devices notice on the 200 spawned workers).
# shellcheck source=lib/show_config.sh
source "$SCRIPT_DIR/lib/show_config.sh"
WIFI_SSID="$SHOW_SSID"
WIFI_PASSWORD="$SHOW_WIFI_PASSWORD"
WIFI_SECURITY="$SHOW_WIFI_SECURITY"
APP_PACKAGE="$SHOW_PACKAGE"

# Seed foreign-show package removals from the active show's config (e.g.
# KAGAMI_BLUE removes the RED show app com.tindrum.kagamu). Config-driven so
# onboarding a show stays a conf edit. Applied only in the provision pass —
# the "Remove apps" section is gated on MODE != check.
if [[ -n "${SHOW_REMOVE_PACKAGES:-}" ]]; then
  # shellcheck disable=SC2206  # intentional word-split: space-separated list
  REMOVE_PACKAGES+=($SHOW_REMOVE_PACKAGES)
fi

# ---- Fleet dispatcher ----------------------------------------------
# Reads the per-show devices file, connects all, spawns --fleet-worker
# per device in parallel, buffers per-device output, prints + summary.

if $FLEET; then
  DEVICES_FILE="$SHOW_DEVICES_FILE"
  if [[ ! -f "$DEVICES_FILE" ]]; then
    echo -e "${RED}devices.txt not found at ${DEVICES_FILE}${RESET}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  if [[ "$MODE" == "check" ]]; then
    echo -e "${BOLD}║   ML2 Fleet Check — Tin Drum                 ║${RESET}"
  else
    echo -e "${BOLD}║   ML2 Fleet Settings — Tin Drum              ║${RESET}"
  fi
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo -e "${DIM}  $TOOLKIT_VERSION${RESET}"
  echo ""

  FLEET_IPS=()
  while IFS= read -r line; do
    [[ "$line" =~ ^\s*# || -z "${line// /}" ]] && continue
    FLEET_IPS+=("$line")
  done < "$DEVICES_FILE"

  echo -e "  Devices in devices.txt: ${CYAN}${#FLEET_IPS[@]}${RESET}"
  echo ""

  echo -e "${CYAN}Connecting...${RESET}"
  CONNECTED=()
  for ip in "${FLEET_IPS[@]}"; do
    if adb connect "${ip}:5555" 2>&1 | grep -q "connected"; then
      echo -e "  ${TICK} $ip"
      CONNECTED+=("${ip}:5555")
    else
      echo -e "  ${CROSS} $ip (failed to connect)"
    fi
  done
  echo ""

  if [[ ${#CONNECTED[@]} -eq 0 ]]; then
    echo -e "${RED}No devices connected.${RESET}"
    exit 1
  fi

  if [[ "$MODE" == "check" ]]; then
    show_banner
  else
    show_confirm "apply settings to ALL ${#CONNECTED[@]} connected"
  fi

  WORKER_ARGS=(--fleet-worker)
  [[ "$MODE" == "check" ]] && WORKER_ARGS+=(--check)

  FLEET_TMP=$(mktemp -d)
  trap 'rm -rf "$FLEET_TMP"' EXIT

  PIDS=()
  for serial in "${CONNECTED[@]}"; do
    ip="${serial%%:*}"
    out="${FLEET_TMP}/${ip}.out"
    exit_f="${FLEET_TMP}/${ip}.exit"
    ( ANDROID_SERIAL="$serial" bash "$0" "${WORKER_ARGS[@]}" >"$out" 2>&1; echo $? >"$exit_f" ) &
    PIDS+=($!)
  done

  printf "  Running on %d device(s)" "${#CONNECTED[@]}"
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
    printf "."
  done
  printf "\n\n"

  SUCCESS=0; FAIL=0
  for serial in "${CONNECTED[@]}"; do
    ip="${serial%%:*}"
    code=$(cat "${FLEET_TMP}/${ip}.exit" 2>/dev/null || echo "1")
    echo -e "────── ${CYAN}${ip}${RESET} ─────────────────────────────────────────"
    cat "${FLEET_TMP}/${ip}.out" 2>/dev/null || true
    if [[ "$code" == "0" ]]; then SUCCESS=$(( SUCCESS + 1 )); else FAIL=$(( FAIL + 1 )); fi
  done

  echo ""
  echo -e "════════════════════════════════════════════════════"
  echo -e "Fleet result — ${GREEN}${SUCCESS}${RESET} succeeded  ${RED}${FAIL}${RESET} failed"
  echo ""
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

# ---- Resolve device ------------------------------------------------

get_serial() {
  local count
  count=$(adb devices | grep -v "List of" | grep "device$" | wc -l | tr -d ' ')
  if [[ "$count" -eq 0 ]]; then
    echo -e "${RED}No device found. Connect via USB and tap 'Allow' for USB debugging.${RESET}" >&2
    exit 1
  fi
  if [[ "$count" -gt 1 ]]; then
    echo -e "${YELLOW}Multiple devices — using first. Set ANDROID_SERIAL to target a specific one.${RESET}" >&2
  fi
  adb devices | grep -v "List of" | grep "device$" | awk '{print $1}' | head -1
}

SERIAL="${ANDROID_SERIAL:-$(get_serial)}"
# </dev/null: these are non-interactive one-shot commands; without it
# `adb shell` consumes the script's stdin, which silently skips the
# later "Press Enter" manual-steps gate in the flash→provision chain.
sh()  { command adb -s "$SERIAL" shell "$@" </dev/null 2>/dev/null | tr -d '\r'; }

DEVICE_SERIAL=$(sh getprop ro.serialno)
MAC=$(sh "ip addr show wlan0 2>/dev/null | grep 'link/ether' | awk '{print \$2}'" || echo "unavailable")
BUILD_ID=$(sh getprop ro.build.id)
LUMIN_VERSION=$(sh getprop ro.build.version.lumin 2>/dev/null | tr -d '\r' || echo "")
CURRENT_OS="${LUMIN_VERSION:-$BUILD_ID}"
MODEL=$(sh getprop ro.product.model)
BUILD_TYPE=$(sh getprop ro.build.type)

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   KAGAMI Device Provisioning — Tin Drum      ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo -e "${DIM}  $TOOLKIT_VERSION${RESET}"
echo ""
echo -e "  Model:          ${CYAN}$MODEL${RESET}"
echo -e "  Device Serial:  ${CYAN}$DEVICE_SERIAL${RESET}"
echo -e "  MAC Address:    ${CYAN}$MAC${RESET}"
echo -e "  ML OS:          ${CYAN}${LUMIN_VERSION:-unknown}${RESET} ($BUILD_ID)"
echo -e "  Build Type:     ${CYAN}$BUILD_TYPE${RESET}"
echo ""

if [[ "$BUILD_ID" != *"$TARGET_BUILD"* ]]; then
  echo -e "${YELLOW}⚠ Warning: build is $BUILD_ID (ML OS ${LUMIN_VERSION:-unknown}), expected $TARGET_BUILD. Run ml_os_flash.sh first?${RESET}"
  echo ""
fi

# ---- Device tracking prompts ---------------------------------------
# Only prompt in full mode, not check or discover
DEVICE_NUMBER="${DEVICE_NUMBER:-}"
CASE_NUMBER="${CASE_NUMBER:-}"
OPERATOR_INITIALS="${OPERATOR_INITIALS:-}"

if [[ "$MODE" == "full" && -z "$DEVICE_NUMBER" && -z "$CASE_NUMBER" ]] && ! $FLEET_WORKER; then
  echo ""
  echo -e "${BOLD}Device tracking${RESET}"
  read -rp "  Device number (or Enter to skip): " DEVICE_NUMBER
  read -rp "  Case number   (press Enter if it matches the device number, or is unknown): " CASE_NUMBER
  read -rp "  Operator initials: " OPERATOR_INITIALS
  echo ""
fi

# Notify sheet that configuration has started
if [[ "$MODE" == "full" ]] && ! $FLEET_WORKER; then
  update_sheet "provision_start" "$DEVICE_SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "false" "$OPERATOR_INITIALS"
fi

if [[ "$MODE" == "discover" ]]; then
  echo "Serial: $DEVICE_SERIAL"
  echo "MAC:    $MAC"
  echo "OS:     $CURRENT_OS ($CURRENT_BUILD)"
  exit 0
fi

# ---- Confirm show (no-op if inherited from the flash chain) --------
if ! $FLEET_WORKER; then
  if [[ "$MODE" == "check" ]]; then
    show_banner
  else
    show_confirm "provision (apply settings + join $SHOW_SSID WiFi)"
  fi
fi


# ---- Helpers -------------------------------------------------------

put_global() { sh "settings put global '$1' '$2'"; }
put_system() { sh "settings put system '$1' '$2'"; }
put_secure() { sh "settings put secure '$1' '$2'"; }
get_global() { sh "settings get global '$1'"; }
get_system() { sh "settings get system '$1'"; }
get_secure() { sh "settings get secure '$1'"; }

MANUAL_STEPS=()

mark_manual() {
  MANUAL_STEPS+=("$1")
  printf "  %b  %-52s ${YELLOW}→ manual${RESET}\n" "$MANUAL" "$1"
}

# These are always required — not settable or verifiable via ADB — registered silently
MANUAL_STEPS+=("Connect controller to device via USB-C → allow firmware update")
MANUAL_STEPS+=("Connect device to laptop — two dialogs will appear:\n        Allow USB debugging → check 'Always allow from this computer' → Allow\n        USB Device Detected → OK")

apply() {
  local label="$1"; shift
  if [[ "$MODE" == "check" ]]; then return 0; fi
  if "$@" &>/dev/null; then
    printf "  %b  %s\n" "$TICK" "$label"
  else
    printf "  %b  ${YELLOW}%s${RESET} ${DIM}(may need userdebug or manual)${RESET}\n" "$CROSS" "$label"
  fi
}

check_val() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf "  %b  %-52s ${DIM}%s${RESET}\n" "$TICK" "$label" "$actual"
  else
    printf "  %b  %-52s ${RED}%s${RESET} ${DIM}(want: %s)${RESET}\n" "$CROSS" "$label" "$actual" "$expected"
  fi
}

check_bool() {
  local label="$1" actual="$2" want_true="$3"
  local ok=false
  [[ "$want_true" == "true"  && ("$actual" == "1" || "$actual" == "true")  ]] && ok=true
  [[ "$want_true" == "false" && ("$actual" == "0" || "$actual" == "false") ]] && ok=true
  if $ok; then
    printf "  %b  %-52s ${DIM}%s${RESET}\n" "$TICK" "$label" "$actual"
  else
    printf "  %b  %-52s ${RED}%s${RESET}\n" "$CROSS" "$label" "$actual"
  fi
}

section() { echo ""; echo -e "${BOLD}── $1 ──────────────────────────────────${RESET}"; }

# ====================================================================
# 1. DEVICE IDENTITY
# ====================================================================
section "Device identity"
printf "  %b  %-52s ${CYAN}%s${RESET}\n" "$TICK" "Serial number" "$DEVICE_SERIAL"
printf "  %b  %-52s ${CYAN}%s${RESET}\n" "$TICK" "MAC address (wlan0)" "$MAC"

# ====================================================================
# 2. DEVELOPER MODE
# ====================================================================
section "Developer mode"

if [[ "$MODE" == "check" ]]; then
  check_bool "Development settings enabled" "$(get_global development_settings_enabled)" "true"
  check_bool "USB debugging (ADB)" "$(get_global adb_enabled)" "true"
  check_val  "ADB auth timeout disabled (never expire)" "$(get_global adb_allowed_connection_time)" "0"
else
  apply "Enable developer mode"  put_global development_settings_enabled 1
  apply "Enable USB debugging"   put_global adb_enabled 1
  # CRITICAL for fleet management: without this, Android revokes the laptop's
  # adb authorization after ~7 days with no connection — even "Always allow" —
  # silently de-authorizing the whole fleet between provisioning and show day.
  # 0 = never expire (the "Disable adb authorization timeout" dev-option). This
  # is why the Pittsburgh fleet went unauthorized after shipping unconnected.
  apply "Disable ADB auth timeout (never expire)" put_global adb_allowed_connection_time 0
  if [[ "$BUILD_TYPE" == "userdebug" ]]; then
    sh "setprop persist.adb.auth 0" &>/dev/null || true
    printf "  %b  Pre-authorized ADB (userdebug build)\n" "$TICK"
  else
    printf "  %b  ADB keys written ${DIM}(user build: 'Allow USB debugging' still required on first connect from each laptop)${RESET}\n" "$TICK"
  fi
fi

# ====================================================================
# 3. BATTERY
# ====================================================================
section "Battery"
# Battery Saver: Off
# Compute Pack Standby: Off

if [[ "$MODE" == "check" ]]; then
  check_bool "Battery Saver: Off"            "$(get_global low_power)"                 "false"
  # stay_on_while_plugged_in: 0=off, 1=AC, 2=USB, 3=AC+USB — any non-zero is pass
  cur_awake=$(get_global stay_on_while_plugged_in)
  if [[ "$cur_awake" != "0" && -n "$cur_awake" ]]; then
    printf "  %b  %-52s ${DIM}%s${RESET}\n" "$TICK" "Stay awake while plugged in" "$cur_awake"
  else
    printf "  %b  %-52s ${RED}%s${RESET}\n" "$CROSS" "Stay awake while plugged in" "${cur_awake:-not set}"
  fi
else
  apply "Battery Saver: Off"              put_global low_power 0
  apply "Stay awake while plugged in"     put_global stay_on_while_plugged_in 3
  apply "Screen timeout: never"           put_system screen_off_timeout 2147483647
  # Attempt ML power service call for Compute Pack Standby — no-op if not supported
  sh "service call power 31 i32 0" &>/dev/null || true
fi
# Not settable via ADB — always requires manual step in headset
mark_manual "Battery → Compute Pack Standby → Off"

# ====================================================================
# 4. DISPLAY
# ====================================================================
section "Display"
# Display Override: Off          — not settable via ADB
# Auto Brightness: Off           — settable
# Brightness: minimum            — settable
# Global Dimming: just below max — not settable via ADB
# Segmented Dimming: On          — not settable via ADB
# Maximum Dimming: just below max — not settable via ADB

if [[ "$MODE" == "check" ]]; then
  check_bool "Auto-brightness: Off"                              "$(get_system screen_brightness_mode)" "false"
  check_val  "Brightness ($SHOW_BRIGHTNESS, from shows/$ML_SHOW.conf)" "$(get_system screen_brightness)" "$SHOW_BRIGHTNESS"
else
  # ── Standard Android ──────────────────────────────────────────
  apply "Auto-brightness: Off"                       put_system screen_brightness_mode 0
  apply "Brightness: $SHOW_BRIGHTNESS (per show conf)" put_system screen_brightness "$SHOW_BRIGHTNESS"

  # ── ML2-specific display service calls ────────────────────────
  # Display Modes → none is already default on fresh flash
  printf "  %b  Display Modes → none (default)\n" "$TICK"

  # Confirmed NOT settable via ADB on 1.4.1 user build — manual required:
  sh "settings put secure ml_segmented_dimming_enabled 0" &>/dev/null || true  # best-effort
  sh "service call SurfaceFlinger 1008 i32 0" &>/dev/null || true              # best-effort
  sh "service call power 31 i32 0" &>/dev/null || true                         # best-effort
fi
# Not settable via ADB — always require manual steps in headset
mark_manual "Display → Display Override → Off"
mark_manual "Display → Global Dimming → just below max, even with h in 'light'"
mark_manual "Display → Segmented Dimming → On"
mark_manual "Display → Maximum Dimming → just below max, even with l in 'display'"

# ====================================================================
# 5. WIFI
# ====================================================================
WIFI_CONNECTED=false
section "WiFi — SSID: $WIFI_SSID"

if [[ "$MODE" == "check" ]] || $FLEET_WORKER; then
  cur_ssid=$(sh "dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo' | grep -o 'SSID: [^,]*' | head -1 | sed 's/SSID: //' | tr -d '\"'" || echo "")
  check_val "Connected SSID" "$cur_ssid" "$WIFI_SSID"
else
  echo "  Connecting..."
  WIFI_CONNECTED=false
  # `cmd wifi` is root-only on the 1.4.1 user build (denied for the
  # adb shell user, uid 2000). wifi-ml is Magic Leap's own CLI, works
  # as the shell user, and is the only path that actually connects on
  # this build. A fresh flash can also leave the radio off.
  sh "wifi-ml set-wifi-enabled enabled" &>/dev/null || true
  sleep 3
  # connect-network blocks up to -t seconds waiting for association;
  # retry a few times since right after a fresh flash the supplicant
  # may not be ready on the first attempt.
  for i in $(seq 1 3); do
    sh "wifi-ml connect-network \"$WIFI_SSID\" $WIFI_SECURITY \"$WIFI_PASSWORD\" -t 30" &>/dev/null || true
    cur_ssid=$(sh "dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo' | grep -o 'SSID: [^,]*' | head -1 | sed 's/SSID: //' | tr -d '\"'" || echo "")
    if [[ "$cur_ssid" == "$WIFI_SSID" ]]; then
      WIFI_CONNECTED=true
      break
    fi
    echo "  Waiting for WiFi association... (attempt $i/3)"
  done
  if $WIFI_CONNECTED; then
    printf "  %b  Connected to %s\n" "$TICK" "$WIFI_SSID"
  else
    printf "  %b  ${YELLOW}Auto-connect failed — network may not be in range${RESET}\n" "$CROSS"
    mark_manual "Settings → Network & Internet → WiFi → $WIFI_SSID / password: $WIFI_PASSWORD"
  fi
fi

# ====================================================================
# 6. OS UPDATER
# ====================================================================
section "OS Updater"
# System → Advanced → OS Updater → Check for updates: Never

if [[ "$MODE" == "check" ]]; then
  cur=$(get_global auto_update_enabled 2>/dev/null || echo "?")
  check_bool "Auto-update disabled" "${cur:-0}" "false"
else
  apply "Disable auto-update (global)" put_global auto_update_enabled 0
  if [[ "$BUILD_TYPE" == "userdebug" ]]; then
    sh "setprop persist.sys.ota.update.disable 1" &>/dev/null || true
    printf "  %b  OTA disabled via setprop\n" "$TICK"
  fi
fi
# Not settable via ADB — always requires manual step in headset
mark_manual "System → Advanced → OS Updater → Check for updates → Never"

# ====================================================================
# 7. APP PERMISSIONS
# ====================================================================
section "App permissions — $APP_PACKAGE"

if ! sh "pm list packages" | grep -q "$APP_PACKAGE"; then
  printf "  %b  ${YELLOW}%s not installed — skipping permissions${RESET}\n" "$SKIP" "$APP_PACKAGE"
  echo "      Install: ./ml_deploy.sh install builds/kagamu.apk"
else
  for perm in "${APP_PERMISSIONS[@]}"; do
    if [[ "$MODE" == "check" ]]; then
      state=$(sh "dumpsys package $APP_PACKAGE 2>/dev/null | grep '$perm'" | grep -o 'granted=true\|granted=false' | head -1 || echo "unknown")
      [[ "$state" == "granted=true" ]] && r="pass" || r="fail"
      if [[ "$r" == "pass" ]]; then
        printf "  %b  %s\n" "$TICK" "$perm"
      else
        printf "  %b  ${RED}%s${RESET} ${DIM}(%s)${RESET}\n" "$CROSS" "$perm" "$state"
      fi
    else
      result=$(sh "pm grant $APP_PACKAGE $perm" 2>&1 || echo "error")
      if echo "$result" | grep -qi "exception\|error"; then
        printf "  %b  ${YELLOW}%s${RESET} ${DIM}(may not be declared in manifest)${RESET}\n" "$CROSS" "$perm"
      else
        printf "  %b  %s\n" "$TICK" "$perm"
      fi
    fi
  done
fi

# ====================================================================
# 8. REMOVE APPS
# ====================================================================
section "Remove apps"

if [[ "$MODE" == "check" ]]; then
  for pkg in "${REMOVE_PACKAGES[@]+"${REMOVE_PACKAGES[@]}"}"; do
    [[ -z "$pkg" ]] && continue
    printf "  %b  %-52s ${DIM}(run without --check to remove)${RESET}\n" "$SKIP" "Check for: $pkg"
  done
else
  # Exact-package removal list (foreign-show + obsolete apps from
  # SHOW_REMOVE_PACKAGES). Exact ids — no fuzzy name matching.
  PKGS_TO_REMOVE=("${REMOVE_PACKAGES[@]+"${REMOVE_PACKAGES[@]}"}")

  if [[ ${#PKGS_TO_REMOVE[@]} -eq 0 ]]; then
    printf "  %b  No packages configured to remove (SHOW_REMOVE_PACKAGES empty)\n" "$SKIP"
    echo ""
    echo -e "  ${DIM}To inspect installed third-party packages:${RESET}"
    echo -e "  ${DIM}  adb -s $SERIAL shell pm list packages -3${RESET}"
  else
    for pkg in "${PKGS_TO_REMOVE[@]}"; do
      [[ -z "$pkg" ]] && continue
      # Check if package is actually installed before attempting removal
      if ! sh "pm list packages" 2>/dev/null | grep -q "^package:${pkg}$"; then
        printf "  %b  %-52s ${DIM}already gone${RESET}\n" "$SKIP" "$pkg"
        continue
      fi
      printf "  Removing: %s\n" "$pkg"
      if sh "pm uninstall --user 0 $pkg" 2>/dev/null | grep -q "Success"; then
        printf "  %b  Removed: %s\n" "$TICK" "$pkg"
      elif sh "pm uninstall $pkg" 2>/dev/null | grep -q "Success"; then
        printf "  %b  Removed: %s\n" "$TICK" "$pkg"
      else
        printf "  %b  ${YELLOW}Could not remove: %s${RESET}\n" "$CROSS" "$pkg"
        mark_manual "Settings → Apps → $pkg → Uninstall"
      fi
    done
  fi
fi

# ====================================================================
# 8b. REMOVE DIRECTORIES
# ====================================================================
section "Remove directories"

if [[ "$MODE" == "check" ]]; then
  for dir in "${REMOVE_DIRS[@]}"; do
    exists=$(sh "[ -d '$dir' ] && echo yes || echo no" 2>/dev/null || echo "unknown")
    if [[ "$exists" == "no" ]]; then
      printf "  %b  %-52s ${DIM}already gone${RESET}\n" "$TICK" "$dir"
    else
      printf "  %b  %-52s ${RED}exists — will be removed on full run${RESET}\n" "$CROSS" "$dir"
    fi
  done
else
  for dir in "${REMOVE_DIRS[@]}"; do
    exists=$(sh "[ -d '$dir' ] && echo yes || echo no" 2>/dev/null || echo "unknown")
    if [[ "$exists" == "no" ]]; then
      printf "  %b  %-52s ${DIM}already gone${RESET}\n" "$SKIP" "$dir"
    else
      printf "  Deleting: %s\n" "$dir"
      if sh "rm -rf '$dir'" 2>/dev/null; then
        printf "  %b  Deleted: %s\n" "$TICK" "$dir"
      else
        printf "  %b  ${YELLOW}Could not delete: %s${RESET}\n" "$CROSS" "$dir"
      fi
    fi
  done
fi

# ====================================================================
# 9. SYSTEM / MISC
# ====================================================================
# ====================================================================
# 9a. INPUT
# ====================================================================
section "Input"
# Hand navigation must be on — controllers may not be paired on every device

if [[ "$MODE" == "check" ]]; then
  check_bool "Hand navigation: On" "$(get_system enable_pinch_gesture_inputs)" "true"
else
  apply "Hand navigation: On" put_system enable_pinch_gesture_inputs 1
fi

# ====================================================================
# 10. SYSTEM / MISC
# ====================================================================
section "System / misc"

if [[ "$MODE" != "check" ]]; then
  apply "Bluetooth: On"                  sh "settings put global bluetooth_on 1"
  apply "Disable notification sounds"    put_system notification_sound ""
  apply "Sound effects: Off"            put_system sound_effects_enabled 0
  apply "Haptic feedback: Off"          put_system haptic_feedback_enabled 0
  apply "Window animation scale: 0"     put_global window_animation_scale 0.0
  apply "Transition animation scale: 0" put_global transition_animation_scale 0.0
  apply "Animator duration scale: 0"    put_global animator_duration_scale 0.0
  apply "Captive portal check: Off"     put_global captive_portal_detection_enabled 0
fi

# ====================================================================
# NETWORK / IDENTITY SUMMARY
# ====================================================================
# ====================================================================
# ADB KEYS — injection DISABLED (2026-06-04)
# ====================================================================
# This block pushed authorized_keys/* into the device's
# /data/misc/adb/adb_keys to pre-authorize operator laptops. It only
# takes effect on ML's non-secure (userdebug) OS builds. On the
# production ML2 1.4.1 *user* build the OS ignores pre-seeded
# adb_keys, so this did nothing in practice and its "All authorized
# keys pushed" output was misleading (it looked like ADB auth was
# handled when it was not). What actually authorizes the fleet is the
# shared fleet key (adbkey_kagami_fleet installed to ~/.android/adbkey
# by install.sh) plus a single in-headset "Allow USB debugging" tap
# per device — one tap per device, not per laptop, because every
# laptop shares that one identity. Re-enable (uncomment) only if you
# are provisioning a userdebug / non-secure build.
#
# if ! $FLEET_WORKER; then
#
# section "ADB key authorization"
#
# ADB_KEY="$HOME/.android/adbkey.pub"
# EXTRA_KEYS_DIR="$(dirname "${BASH_SOURCE[0]}")/authorized_keys"
# ALL_KEYS_TMP=$(mktemp)
#
# if [[ -f "$ADB_KEY" ]]; then
#   cat "$ADB_KEY" >> "$ALL_KEYS_TMP"
#   echo "" >> "$ALL_KEYS_TMP"
# fi
# if [[ -d "$EXTRA_KEYS_DIR" ]]; then
#   for keyfile in "$EXTRA_KEYS_DIR"/*.pub; do
#     [[ -f "$keyfile" ]] || continue
#     cat "$keyfile" >> "$ALL_KEYS_TMP"
#     echo "" >> "$ALL_KEYS_TMP"
#   done
# fi
#
# if [[ -s "$ALL_KEYS_TMP" ]]; then
#   KEY_COUNT=$(grep -c "." "$ALL_KEYS_TMP" 2>/dev/null || echo "0")
#   command adb -s "$SERIAL" push "$ALL_KEYS_TMP" /data/misc/adb/adb_keys &>/dev/null &&     sh "chmod 0640 /data/misc/adb/adb_keys" 2>/dev/null || true
#   sh "setprop ctl.restart adbd" 2>/dev/null || true
#   sleep 1
#   printf "  %b  %-52s ${DIM}%s keys${RESET}\n" "$TICK" "All authorized keys pushed" "$KEY_COUNT"
# else
#   printf "  %b  No keys found in authorized_keys/\n" "$CROSS"
# fi
# rm -f "$ALL_KEYS_TMP"
#
# fi  # end ! FLEET_WORKER (ADB key authorization)

section "Network"
sleep 3
DEVICE_IP=$(sh "ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" || echo "not connected")
printf "  %b  %-52s ${CYAN}%s${RESET}\n" "$TICK" "Device IP" "$DEVICE_IP"


# ====================================================================
# DONE
# ====================================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"

if [[ "$MODE" != "check" ]]; then
  if $FLEET_WORKER; then
    echo -e "${GREEN}${BOLD}Settings applied.${RESET}"
  else
    # Append to provisioning log
    LOG_FILE="$(dirname "${BASH_SOURCE[0]}")/provisioned_devices.csv"
    [[ ! -f "$LOG_FILE" ]] && echo "timestamp,device_number,case_number,operator,serial,mac,ip,ml_os,build_id,build_type" > "$LOG_FILE"
    echo "$(date +%Y-%m-%dT%H:%M:%S),$DEVICE_NUMBER,$CASE_NUMBER,$OPERATOR_INITIALS,$DEVICE_SERIAL,$MAC,$DEVICE_IP,${LUMIN_VERSION:-$BUILD_ID},$BUILD_ID,$BUILD_TYPE" >> "$LOG_FILE"
    echo -e "${GREEN}${BOLD}Provisioning complete.${RESET}  ${DIM}(logged to provisioned_devices.csv)${RESET}"
    update_sheet "provision_complete" "$DEVICE_SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "$WIFI_CONNECTED" "$OPERATOR_INITIALS"
  fi
else
  echo -e "${BOLD}Check complete.${RESET}"
fi

if [[ ${#MANUAL_STEPS[@]} -gt 0 ]] && ! $FLEET_WORKER; then
  echo ""
  echo -e "${YELLOW}${BOLD}Manual steps — put on headset and complete:${RESET}"
  for step in "${MANUAL_STEPS[@]}"; do
    echo -e "  ${YELLOW}[ ]${RESET} $step"
  done
  echo ""
  if [[ "$CHAIN_DEPLOY" == true ]]; then
    # Read from the controlling terminal, not stdin — in the chained
    # flow stdin may be drained/redirected, which would skip this gate.
    read -rp "  Press Enter when manual steps are complete to begin APK install..." </dev/tty
    echo ""
  fi
fi

echo ""
{ [[ -n "$DEVICE_NUMBER" ]]     && ! $FLEET_WORKER; } && echo -e "  Device #:      ${CYAN}$DEVICE_NUMBER${RESET}"
{ [[ -n "$CASE_NUMBER" ]]       && ! $FLEET_WORKER; } && echo -e "  Case #:        ${CYAN}$CASE_NUMBER${RESET}"
{ [[ -n "$OPERATOR_INITIALS" ]] && ! $FLEET_WORKER; } && echo -e "  Operator:      ${CYAN}$OPERATOR_INITIALS${RESET}"
echo -e "  Device Serial: ${CYAN}$DEVICE_SERIAL${RESET}"
echo -e "  Device IP:     ${CYAN}$DEVICE_IP${RESET}"
echo -e "  MAC Address:   ${CYAN}$MAC${RESET}"
if ! $FLEET_WORKER; then
  echo -e "  To add:        ${DIM}echo '$DEVICE_IP' >> devices.txt${RESET}"
fi
echo ""

if ! $FLEET_WORKER; then
  # Copy serial number to clipboard for easy entry into tracking spreadsheet
  if command -v pbcopy &>/dev/null; then
    echo -n "$DEVICE_SERIAL" | pbcopy
    echo -e "  ${GREEN}✓ Serial number copied to clipboard${RESET}"
  fi
  echo ""

  # ---- Auto-deploy over USB -----------------------------------------
  DEPLOY_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/ml_deploy.sh"

  if [[ "$CHAIN_DEPLOY" == true ]]; then
    if [[ -f "$DEPLOY_SCRIPT" ]]; then
      echo ""
      echo -e "${CYAN}Running initial deploy over USB...${RESET}"
      echo ""
      ANDROID_SERIAL="$SERIAL" bash "$DEPLOY_SCRIPT" --all
      update_sheet "deploy_complete" "$DEVICE_SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "" "$OPERATOR_INITIALS"
    else
      echo -e "${YELLOW}ml_deploy.sh not found — skipping auto-deploy${RESET}"
    fi
  fi

  # Enable WiFi ADB — last USB ADB command; USB connection drops after this
  if [[ "$MODE" != "check" ]]; then
    adb -s "$SERIAL" tcpip 5555 &>/dev/null || true
    printf "  %b  WiFi ADB enabled on port 5555 — device reachable at %s\n" "$TICK" "$DEVICE_IP"
  fi
fi
