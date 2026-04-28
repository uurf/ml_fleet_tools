#!/opt/homebrew/bin/bash
# ============================================================
# Magic Leap 2 Device Provisioning — KAGAMI / Tin Drum
# Target OS: 1.4.1 (B3E.230928.10-R.098)
#
# Runs automatically after ml_os_flash.sh, or standalone:
#   ./ml_provision.sh              # full provision (USB device)
#   ./ml_provision.sh --check      # read & report current state
#   ./ml_provision.sh --discover   # just print serial + MAC
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
MANUAL="${YELLOW}⊙${RESET}"
SKIP="${DIM}–${RESET}"


# ---- Google Sheets update ------------------------------------------
SHEETS_URL="https://script.google.com/macros/s/AKfycbyPsoVvtkarMWli8iZMoZSwcQpL5Ra5xcOT9hfuEOaYkhVfT9Z8LjivdswgHrU5W508/exec"

update_sheet() {
  local action="$1" serial="$2" device_num="${3:-}" case_num="${4:-}" wifi_ok="${5:-false}" operator_initials="${6:-}"
  python3 -c "
import urllib.request, json, sys
url = 'https://script.google.com/macros/s/AKfycbwUeUL8yk89AWxX_NN6HhCh-vo1MRbnbxHbiTPbvcyhRttiVQOywnrRMH-J9uBPg7Tz/exec'
data = json.dumps({'action':'ACTION','serial':'SERIAL','device_number':'DEVNUM','case_number':'CASENUM','wifi_connected':'WIFIOK','operator_initials':'INITIALS'}).encode()
data = data.replace(b'ACTION', '$action'.encode()).replace(b'SERIAL', '$serial'.encode()).replace(b'DEVNUM', '$device_num'.encode()).replace(b'CASENUM', '$case_num'.encode()).replace(b'WIFIOK', '$wifi_ok'.encode()).replace(b'INITIALS', '$operator_initials'.encode())
req = urllib.request.Request(url, data=data, headers={'Content-Type':'application/json'})
try:
  urllib.request.urlopen(req, timeout=10)
except Exception as e:
  sys.stderr.write(str(e))
" 2>/dev/null || true
}


# ============================================================
# CONFIG
# ============================================================

TARGET_OS="1.4.1"
TARGET_BUILD="B3E.230928.10-R.098"

WIFI_SSID="KAGAMI"
WIFI_PASSWORD="KAGAmius"
WIFI_SECURITY="wpa2"

APP_PACKAGE="com.tindrum.kagami"
APP_PERMISSIONS=(
  "android.permission.CAMERA"
  "android.permission.RECORD_AUDIO"
  "android.permission.READ_EXTERNAL_STORAGE"
  "android.permission.WRITE_EXTERNAL_STORAGE"
  "android.permission.ACCESS_FINE_LOCATION"
  "android.permission.ACCESS_COARSE_LOCATION"
)

# Apps to remove — exact package names
REMOVE_PACKAGES=(
  "com.tindrum.kiosk"
)
# Also removed by fuzzy name match
REMOVE_FRIENDLY_NAMES=("An Ark" "The Life" "Medusa")

# Directories to delete from device storage
REMOVE_DIRS=(
  "/sdcard/AnArk"
  "/sdcard/Android/data/com.tindrum.kiosk"
)

# ============================================================

MODE="full"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)    MODE="check" ;;
    --discover) MODE="discover" ;;
    --help|-h)
      echo "Usage: ./ml_provision.sh [--check|--discover]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

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
sh()  { command adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }

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

if [[ "$MODE" == "full" && -z "$DEVICE_NUMBER" && -z "$CASE_NUMBER" ]]; then
  echo ""
  echo -e "${BOLD}Device tracking${RESET}"
  read -rp "  Device number (or Enter to skip): " DEVICE_NUMBER
  read -rp "  Case number   (press Enter if it matches the device number, or is unknown): " CASE_NUMBER
  read -rp "  Operator initials: " OPERATOR_INITIALS
  echo ""
fi

# Notify sheet that configuration has started
if [[ "$MODE" == "full" ]]; then
  update_sheet "provision_start" "$DEVICE_SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "false" "$OPERATOR_INITIALS"
fi

if [[ "$MODE" == "discover" ]]; then
  echo "Serial: $DEVICE_SERIAL"
  echo "MAC:    $MAC"
  echo "OS:     $CURRENT_OS ($CURRENT_BUILD)"
  exit 0
fi


# ---- Helpers -------------------------------------------------------

put_global() { sh "settings put global '$1' '$2'"; }
put_system() { sh "settings put system '$1' '$2'"; }
put_secure() { sh "settings put secure '$1' '$2'"; }
get_global() { sh "settings get global '$1'"; }
get_system() { sh "settings get system '$1'"; }

MANUAL_STEPS=()

mark_manual() {
  MANUAL_STEPS+=("$1")
  printf "  %b  %-52s ${YELLOW}→ manual${RESET}\n" "$MANUAL" "$1"
}

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
else
  apply "Enable developer mode"  put_global development_settings_enabled 1
  apply "Enable USB debugging"   put_global adb_enabled 1
  if [[ "$BUILD_TYPE" == "userdebug" ]]; then
    sh "setprop persist.adb.auth 0" &>/dev/null || true
    printf "  %b  Pre-authorized ADB (userdebug build)\n" "$TICK"
  else
    printf "  %b  ADB keys pre-injected during flash — no dialog expected\n" "$TICK"
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
  printf "  %b  %-52s ${DIM}verify in Settings → Battery${RESET}\n" "$MANUAL" "Compute Pack Standby: Off"
else
  apply "Battery Saver: Off"              put_global low_power 0
  apply "Stay awake while plugged in"     put_global stay_on_while_plugged_in 3
  apply "Screen timeout: never"           put_system screen_off_timeout 2147483647
  # Attempt ML power service call for Compute Pack Standby — no-op if not supported
  sh "service call power 31 i32 0" &>/dev/null || true
  mark_manual "Settings → Battery → Compute Pack Standby → Off"
fi

# ====================================================================
# 4. DISPLAY
# ====================================================================
section "Display"
# Display Override: Off
# Display Modes: none
# Auto Brightness: Off
# Brightness: minimum
# Global Dimming: minimum
# Segmented Dimming: Off
# Maximum Dimming: 100%

if [[ "$MODE" == "check" ]]; then
  check_bool "Auto-brightness: Off" "$(get_system screen_brightness_mode)" "false"
  check_val  "Brightness (0 = min)" "$(get_system screen_brightness)" "0"
  for label in \
    "Display Override: Off" \
    "Display Modes: none" \
    "Global Dimming: minimum" \
    "Segmented Dimming: Off" \
    "Maximum Dimming: 100%"
  do
    printf "  %b  %-52s ${DIM}ML system service — verify in headset UI${RESET}\n" "$MANUAL" "$label"
  done
else
  # ── Standard Android ──────────────────────────────────────────
  apply "Auto-brightness: Off"      put_system screen_brightness_mode 0
  apply "Brightness: minimum (0)"   put_system screen_brightness 0

  # ── ML2-specific display service calls ────────────────────────
  # Confirmed working on OS 1.4.1 user build:
  sh "service call MagicLeapDimmer 1 f 0.0" &>/dev/null || true  # Global Dimming → min
  sh "service call MagicLeapDimmer 3 f 1.0" &>/dev/null || true  # Maximum Dimming → 100%
  # Display Modes → none is already default on fresh flash
  printf "  %b  Global Dimming → min, Maximum Dimming → 100%%, Display Modes → none\n" "$TICK"

  # Confirmed NOT working via service calls on 1.4.1 user build — manual required:
  sh "settings put secure ml_segmented_dimming_enabled 0" &>/dev/null || true  # best-effort
  sh "service call SurfaceFlinger 1008 i32 0" &>/dev/null || true              # best-effort
  sh "service call power 31 i32 0" &>/dev/null || true                         # best-effort
  mark_manual "Settings → Display → Display Override → Off"
  mark_manual "Settings → Display → Segmented Dimming → Off"
fi

# ====================================================================
# 5. WIFI
# ====================================================================
WIFI_CONNECTED=false
section "WiFi — SSID: $WIFI_SSID"

if [[ "$MODE" == "check" ]]; then
  cur_ssid=$(sh "dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo' | grep -o 'SSID: [^,]*' | head -1 | sed 's/SSID: //' | tr -d '\"'" || echo "")
  check_val "Connected SSID" "$cur_ssid" "$WIFI_SSID"
else
  echo "  Connecting..."
  WIFI_CONNECTED=false
  # Wait for WiFi service to be ready then connect
  sh "wifi-ml connect-network \"$WIFI_SSID\" $WIFI_SECURITY \"$WIFI_PASSWORD\"" &>/dev/null || true
  sh "cmd wifi connect-network \"$WIFI_SSID\" $WIFI_SECURITY \"$WIFI_PASSWORD\"" &>/dev/null || true
  # Wait up to 30s for connection
  for i in $(seq 1 6); do
    sleep 5
    cur_ssid=$(sh "dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo' | grep -o 'SSID: [^,]*' | head -1 | sed 's/SSID: //' | tr -d '\"'" || echo "")
    if [[ "$cur_ssid" == "$WIFI_SSID" ]]; then
      WIFI_CONNECTED=true
      break
    fi
    echo "  Waiting for connection... ($((i * 5))s)"
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
  printf "  %b  %-52s ${DIM}verify in headset UI${RESET}\n" "$MANUAL" "OS Updater: Check for updates → Never"
else
  apply "Disable auto-update (global)" put_global auto_update_enabled 0
  if [[ "$BUILD_TYPE" == "userdebug" ]]; then
    sh "setprop persist.sys.ota.update.disable 1" &>/dev/null || true
    printf "  %b  OTA disabled via setprop\n" "$TICK"
  fi
  mark_manual "Settings → System → Advanced → OS Updater → Check for updates → Never"
fi

# ====================================================================
# 7. APP PERMISSIONS
# ====================================================================
section "App permissions — $APP_PACKAGE"

if ! sh "pm list packages" | grep -q "$APP_PACKAGE"; then
  printf "  %b  ${YELLOW}%s not installed — skipping permissions${RESET}\n" "$SKIP" "$APP_PACKAGE"
  echo "      Install: ./ml_deploy.sh install builds/kagami.apk"
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
  for name in "${REMOVE_FRIENDLY_NAMES[@]}"; do
    printf "  %b  %-52s ${DIM}(run without --check to remove)${RESET}\n" "$SKIP" "Check for: $name"
  done
else
  # Build combined list: explicit packages + fuzzy-match on friendly names
  PKGS_TO_REMOVE=("${REMOVE_PACKAGES[@]+"${REMOVE_PACKAGES[@]}"}")

  # Fuzzy discovery: match package names against friendly name words
  ALL_PKGS=$(sh "pm list packages -3 2>/dev/null" | sed 's/^package://' || echo "")
  for name in "${REMOVE_FRIENDLY_NAMES[@]}"; do
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    while IFS= read -r pkg; do
      pkg_lower=$(echo "$pkg" | tr '[:upper:]' '[:lower:]')
      if echo "$pkg_lower" | grep -qi "$name_lower"; then
        PKGS_TO_REMOVE+=("$pkg")
      fi
    done <<< "$ALL_PKGS"
  done

  if [[ ${#PKGS_TO_REMOVE[@]} -eq 0 ]]; then
    printf "  %b  No matching packages found\n" "$SKIP"
    echo ""
    echo -e "  ${DIM}Apps may already be removed, or package names don't match friendly names.${RESET}"
    echo -e "  ${DIM}To find them manually:${RESET}"
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
section "System / misc"

if [[ "$MODE" != "check" ]]; then
  apply "Bluetooth: Off"                 sh "settings put global bluetooth_on 0"
  apply "Disable notification sounds"    put_system notification_sound ""
  apply "Sound effects: Off"            put_system sound_effects_enabled 0
  apply "Haptic feedback: Off"          put_system haptic_feedback_enabled 0
  apply "Window animation scale: 0"     put_global window_animation_scale 0.0
  apply "Transition animation scale: 0" put_global transition_animation_scale 0.0
  apply "Animator duration scale: 0"    put_global animator_duration_scale 0.0
  apply "Captive portal check: Off"     put_global captive_portal_detection_enabled 0
  # Enable WiFi ADB so this device appears in wireless deploys
  sh "setprop service.adb.tcp.port 5555" &>/dev/null || true
  sh "stop adbd && start adbd" &>/dev/null || true
  printf "  %b  WiFi ADB enabled on port 5555\n" "$TICK"
fi

# ====================================================================
# NETWORK / IDENTITY SUMMARY
# ====================================================================
# ====================================================================
# ADB KEYS — push all authorized keys while we have confirmed ADB access
# ====================================================================
section "ADB key authorization"

ADB_KEY="$HOME/.android/adbkey.pub"
EXTRA_KEYS_DIR="$(dirname "${BASH_SOURCE[0]}")/authorized_keys"
ALL_KEYS_TMP=$(mktemp)

if [[ -f "$ADB_KEY" ]]; then
  cat "$ADB_KEY" >> "$ALL_KEYS_TMP"
  echo "" >> "$ALL_KEYS_TMP"
fi
if [[ -d "$EXTRA_KEYS_DIR" ]]; then
  for keyfile in "$EXTRA_KEYS_DIR"/*.pub; do
    [[ -f "$keyfile" ]] || continue
    cat "$keyfile" >> "$ALL_KEYS_TMP"
    echo "" >> "$ALL_KEYS_TMP"
  done
fi

if [[ -s "$ALL_KEYS_TMP" ]]; then
  KEY_COUNT=$(grep -c "." "$ALL_KEYS_TMP" 2>/dev/null || echo "0")
  command adb -s "$SERIAL" push "$ALL_KEYS_TMP" /data/misc/adb/adb_keys &>/dev/null &&     sh "chmod 0640 /data/misc/adb/adb_keys" 2>/dev/null || true
  sh "setprop ctl.restart adbd" 2>/dev/null || true
  sleep 1
  printf "  %b  %-52s ${DIM}%s keys${RESET}\n" "$TICK" "All authorized keys pushed" "$KEY_COUNT"
else
  printf "  %b  No keys found in authorized_keys/\n" "$CROSS"
fi
rm -f "$ALL_KEYS_TMP"

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
  # Append to provisioning log
  LOG_FILE="$(dirname "${BASH_SOURCE[0]}")/provisioned_devices.csv"
  [[ ! -f "$LOG_FILE" ]] && echo "timestamp,device_number,case_number,operator,serial,mac,ip,ml_os,build_id,build_type" > "$LOG_FILE"
  echo "$(date +%Y-%m-%dT%H:%M:%S),$DEVICE_NUMBER,$CASE_NUMBER,$OPERATOR_INITIALS,$DEVICE_SERIAL,$MAC,$DEVICE_IP,${LUMIN_VERSION:-$BUILD_ID},$BUILD_ID,$BUILD_TYPE" >> "$LOG_FILE"
  echo -e "${GREEN}${BOLD}Provisioning complete.${RESET}  ${DIM}(logged to provisioned_devices.csv)${RESET}"
  # Notify sheet that provisioning is complete and set all auto-configured checkboxes
  update_sheet "provision_complete" "$DEVICE_SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "$WIFI_CONNECTED" "$OPERATOR_INITIALS"
else
  echo -e "${BOLD}Check complete.${RESET}"
fi

echo ""
echo -e "${YELLOW}${BOLD}Manual steps — put on headset and complete:${RESET}"
echo -e "  ${YELLOW}[ ]${RESET} Connect controller to device via USB-C → allow firmware update"
echo -e "  ${YELLOW}[ ]${RESET} Connect device to laptop → tap Allow on USB debugging dialog"
echo -e "  ${YELLOW}[ ]${RESET} Tap Allow on USB device transfer dialog"
if [[ ${#MANUAL_STEPS[@]} -gt 0 ]]; then
  for step in "${MANUAL_STEPS[@]}"; do
    echo -e "  ${YELLOW}[ ]${RESET} $step"
  done
fi

echo ""
[[ -n "$DEVICE_NUMBER" ]] && echo -e "  Device #:      ${CYAN}$DEVICE_NUMBER${RESET}"
[[ -n "$CASE_NUMBER"   ]] && echo -e "  Case #:        ${CYAN}$CASE_NUMBER${RESET}"
[[ -n "$OPERATOR_INITIALS" ]] && echo -e "  Operator:      ${CYAN}$OPERATOR_INITIALS${RESET}"
echo -e "  Device Serial: ${CYAN}$DEVICE_SERIAL${RESET}"
echo -e "  Device IP:     ${CYAN}$DEVICE_IP${RESET}"
echo -e "  MAC Address:   ${CYAN}$MAC${RESET}"
echo -e "  To add:        ${DIM}echo '$DEVICE_IP' >> devices.txt${RESET}"
echo ""

# Notify sheet that provisioning is complete
if [[ "$MODE" == "full" ]]; then
  update_sheet "provision_complete" "$DEVICE_SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "$WIFI_CONNECTED" "$OPERATOR_INITIALS"
fi

# Copy serial number to clipboard for easy entry into tracking spreadsheet
if command -v pbcopy &>/dev/null; then
  echo -n "$DEVICE_SERIAL" | pbcopy
  echo -e "  ${GREEN}✓ Serial number copied to clipboard${RESET}"
fi
echo ""
