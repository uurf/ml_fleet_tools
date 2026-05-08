#!/usr/bin/env bash
# ============================================================
# Magic Leap 2 Fleet Status Collector — KAGAMI / Tin Drum
#
# Collects OS version, APK version, and key settings from
# all online devices in parallel, then outputs a summary.
#
# Usage:
#   ./ml_status.sh                        # table to terminal
#   ./ml_status.sh --json                 # raw JSON
#   ./ml_status.sh --csv                  # CSV for spreadsheet
#   ./ml_status.sh --failures             # only show problem devices
#   ./ml_status.sh --fix                  # auto-fix bad settings
#   ./ml_status.sh --expected-kagami 2.1.0 --expected-kiosk 1.0.0
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.txt"
STATUS_DIR="$SCRIPT_DIR/status"
MAX_PARALLEL=30

# ---- Check for toolkit updates -------------------------------------
# Requires network — silently skips if offline.
# Hard stops if local repo is behind origin/main.
check_for_updates() {
  if ! git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null; then
    echo -e "${YELLOW}⚠ No network — skipping update check.${RESET}" >&2
    return 0
  fi

  local local_sha origin_sha
  local_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
  origin_sha=$(git -C "$SCRIPT_DIR" rev-parse origin/main 2>/dev/null)

  if [[ "$local_sha" != "$origin_sha" ]]; then
    echo ""
    echo -e "${RED}┌─────────────────────────────────────────────────┐${RESET}" >&2
    echo -e "${RED}│  Toolkit is out of date — please update first   │${RESET}" >&2
    echo -e "${RED}└─────────────────────────────────────────────────┘${RESET}" >&2
    echo ""
    echo -e "  Run: ${CYAN}./update.sh${RESET}" >&2
    echo ""
    exit 1
  fi
}
TOOLKIT_VERSION=$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "unversioned")
check_for_updates

# ── Defaults (override via args or edit here) ────────────────
PKG_KAGAMI="com.tindrum.kagamu"
PKG_KIOSK="com.tindrum.kiosk"
EXPECTED_OS="${ML_EXPECTED_OS:-}"        # e.g. "1.3.2" — leave blank to skip check
EXPECTED_KAGAMI="${ML_EXPECTED_KAGAMI:-}"  # e.g. "2.1.0" — leave blank to skip check
EXPECTED_KIOSK="${ML_EXPECTED_KIOSK:-}"   # e.g. "1.0.0" — leave blank to skip check

# ── Expected settings (pass/fail logic) ─────────────────────
WANT_STAY_AWAKE="1"        # 1 = stay awake while charging
WANT_WIFI="1"              # must be connected
WANT_BT="0"                # 0 = bluetooth off for show
WANT_BRIGHTNESS="50"       # expected brightness level (0-255), blank to skip
WANT_DEV_MODE="1"          # developer mode on
WANT_USB_DEBUG="1"         # USB debugging on
WANT_AUTO_UPDATE="0"       # auto-update off

# ── Output mode ──────────────────────────────────────────────
MODE="table"   # table | json | csv
FAILURES_ONLY=false
AUTO_FIX=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"; CROSS="${RED}✗${RESET}"; WARN="${YELLOW}~${RESET}"

# ── Arg parsing ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)       MODE="json" ;;
    --csv)        MODE="csv" ;;
    --failures)   FAILURES_ONLY=true ;;
    --fix)        AUTO_FIX=true ;;
    --expected-os)      EXPECTED_OS="$2"; shift ;;
    --expected-kagami)  EXPECTED_KAGAMI="$2"; shift ;;
    --expected-kiosk)   EXPECTED_KIOSK="$2"; shift ;;
    -f)           DEVICES_FILE="$2"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

mkdir -p "$STATUS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$STATUS_DIR/$TIMESTAMP"
mkdir -p "$RUN_DIR"

# ── Load devices ─────────────────────────────────────────────
load_devices() {
  grep -v '^\s*#' "$DEVICES_FILE" | grep -v '^\s*$' || true
}

online_devices() {
  adb devices | grep -v "List of" | grep "device$" | awk '{print $1}' || true
}

# ── Collect data from a single device ────────────────────────
collect_device() {
  local serial="$1"
  local out="$RUN_DIR/${serial//:/_}.json"

  adb_s() { adb -s "$serial" shell "$@" 2>/dev/null | tr -d '\r' || echo ""; }

  # ── Versions ─────────────────────────────────────────────
  local os_version
  os_version=$(adb_s getprop ro.build.version.lumin)

  local build_id
  build_id=$(adb_s getprop ro.build.id)

  get_apk_version() {
    local pkg="$1"
    if adb -s "$serial" shell pm list packages 2>/dev/null | grep -q "$pkg"; then
      local ver code
      ver=$(adb_s "dumpsys package $pkg" | grep versionName | head -1 | sed 's/.*versionName=//')
      code=$(adb_s "dumpsys package $pkg" | grep versionCode | head -1 | sed 's/.*versionCode=//; s/ .*//')
      echo "true|$ver|$code"
    else
      echo "false||"
    fi
  }

  local kagami_info kiosk_info
  kagami_info=$(get_apk_version "$PKG_KAGAMI")
  kiosk_info=$(get_apk_version "$PKG_KIOSK")

  local kagami_installed kagami_version kagami_code
  IFS='|' read -r kagami_installed kagami_version kagami_code <<< "$kagami_info"
  local kiosk_installed kiosk_version kiosk_code
  IFS='|' read -r kiosk_installed kiosk_version kiosk_code <<< "$kiosk_info"

  # ── Settings ─────────────────────────────────────────────
  local stay_awake
  stay_awake=$(adb_s settings get global stay_on_while_plugged_in)
  # ML2: value 3 = stay awake on AC+USB, 1 = AC only, 0 = off
  # Normalize: any non-zero = awake
  [[ "$stay_awake" == "null" || "$stay_awake" == "" ]] && stay_awake="0"
  local stay_awake_on="false"
  [[ "$stay_awake" != "0" ]] && stay_awake_on="true"

  local wifi_ssid
  wifi_ssid=$(adb_s "dumpsys wifi" | grep "mWifiInfo" | grep -o 'SSID: [^,]*' | sed 's/SSID: //' | tr -d '"' | head -1 || echo "")
  local wifi_connected="false"
  [[ -n "$wifi_ssid" && "$wifi_ssid" != "<unknown ssid>" ]] && wifi_connected="true"

  local bt_enabled
  bt_enabled=$(adb_s settings get global bluetooth_on)
  [[ "$bt_enabled" == "null" || "$bt_enabled" == "" ]] && bt_enabled="0"
  local bt_on="false"
  [[ "$bt_enabled" == "1" ]] && bt_on="true"

  local brightness
  brightness=$(adb_s settings get system screen_brightness)
  [[ "$brightness" == "null" || "$brightness" == "" ]] && brightness="0"

  local dev_mode
  dev_mode=$(adb_s settings get global development_settings_enabled)
  [[ "$dev_mode" == "null" || "$dev_mode" == "" ]] && dev_mode="0"
  local dev_on="false"
  [[ "$dev_mode" == "1" ]] && dev_on="true"

  local usb_debug
  usb_debug=$(adb_s settings get global adb_enabled)
  [[ "$usb_debug" == "null" || "$usb_debug" == "" ]] && usb_debug="0"
  local usb_on="false"
  [[ "$usb_debug" == "1" ]] && usb_on="true"

  # ML2 uses OTA update system — check if auto-update is suppressed
  local auto_update
  auto_update=$(adb_s settings get global auto_update_enabled 2>/dev/null || echo "")
  [[ -z "$auto_update" || "$auto_update" == "null" ]] && auto_update=$(adb_s getprop persist.sys.ota.update.disable 2>/dev/null || echo "")
  local auto_update_off="false"
  [[ "$auto_update" == "0" || "$auto_update" == "1" && "$(adb_s getprop persist.sys.ota.update.disable)" == "1" ]] && auto_update_off="true"
  # Fallback: if property not set, mark as unknown
  [[ -z "$auto_update" || "$auto_update" == "null" ]] && auto_update="unknown" && auto_update_off="unknown"

  local battery
  battery=$(adb_s "dumpsys battery" | grep level | awk '{print $2}')

  # ── Write JSON ───────────────────────────────────────────
  cat > "$out" <<EOF
{
  "serial": "$serial",
  "ip": "${serial%%:*}",
  "timestamp": "$TIMESTAMP",
  "os_version": "$os_version",
  "build_id": "$build_id",
  "battery": "$battery",
  "kagami": {
    "package": "$PKG_KAGAMI",
    "installed": $kagami_installed,
    "version": "$kagami_version",
    "version_code": "$kagami_code"
  },
  "kiosk": {
    "package": "$PKG_KIOSK",
    "installed": $kiosk_installed,
    "version": "$kiosk_version",
    "version_code": "$kiosk_code"
  },
  "settings": {
    "stay_awake": $stay_awake_on,
    "stay_awake_raw": "$stay_awake",
    "wifi_connected": $wifi_connected,
    "wifi_ssid": "$wifi_ssid",
    "bluetooth_on": $bt_on,
    "screen_brightness": $brightness,
    "developer_mode": $dev_on,
    "usb_debugging": $usb_on,
    "auto_update_off": "$auto_update_off"
  }
}
EOF
}

export -f collect_device 2>/dev/null || true

# ── Auto-fix bad settings on a device ────────────────────────
fix_device() {
  local serial="$1"
  local data_file="$RUN_DIR/${serial//:/_}.json"
  [[ ! -f "$data_file" ]] && return

  adb_set() { adb -s "$serial" shell settings put "$@" 2>/dev/null; }

  local stay_awake
  stay_awake=$(python3 -c "import json,sys; d=json.load(open('$data_file')); print(d['settings']['stay_awake'])" 2>/dev/null)
  [[ "$stay_awake" == "false" ]] && adb_set global stay_on_while_plugged_in 3

  local bt_on
  bt_on=$(python3 -c "import json,sys; d=json.load(open('$data_file')); print(d['settings']['bluetooth_on'])" 2>/dev/null)
  [[ "$bt_on" == "true" ]] && adb -s "$serial" shell service call bluetooth_manager 8 2>/dev/null || true

  # Brightness
  local brightness
  brightness=$(python3 -c "import json,sys; d=json.load(open('$data_file')); print(d['settings']['screen_brightness'])" 2>/dev/null)
  [[ -n "$WANT_BRIGHTNESS" && "$brightness" != "$WANT_BRIGHTNESS" ]] && \
    adb_set system screen_brightness "$WANT_BRIGHTNESS"

  echo "  Fixed: $serial"
}
export -f fix_device 2>/dev/null || true

# ── Check a value pass/fail ───────────────────────────────────
check() {
  local val="$1" want="$2"
  if [[ "$want" == "" ]]; then echo "skip"; return; fi
  if [[ "$val" == "$want" || "$val" == "true" && "$want" == "1" || "$val" == "false" && "$want" == "0" ]]; then
    echo "pass"
  else
    echo "fail"
  fi
}

# ── Render table ─────────────────────────────────────────────
render_table() {
  local files=("$RUN_DIR"/*.json)
  local total=0 pass_all=0 fail_count=0

  # Header
  printf "\n"
  printf "${BOLD}%-18s %-8s %-12s %-12s %-7s  %s  %s  %s  %s  %s  %s  %s  %s${RESET}\n" \
    "IP" "OS" "Kagami" "Kiosk" "Batt%" "Sleep" "WiFi" "BT✗" "Bright" "Dev" "USB" "NoUpd" "OK?"
  printf "%-18s %-8s %-12s %-12s %-7s  %s  %s  %s  %s  %s  %s  %s  %s\n" \
    "──────────────────" "────────" "────────────" "────────────" "───────" "─────" "─────" "─────" "──────" "─────" "─────" "─────" "───"

  for f in "${files[@]}"; do
    [[ ! -f "$f" ]] && continue
    ((total++)) || true

    # Parse JSON with python3 (available on macOS)
    read -r ip os_ver kagami_ver kiosk_ver battery stay_awake wifi_ok wifi_ssid bt_on brightness dev_on usb_on auto_off <<< \
      "$(python3 -c "
import json, sys
d = json.load(open('$f'))
s = d['settings']
print(
  d['ip'],
  d['os_version'],
  d['kagami']['version'] if d['kagami']['installed'] else 'MISSING',
  d['kiosk']['version'] if d['kiosk']['installed'] else 'MISSING',
  d['battery'],
  str(s['stay_awake']).lower(),
  str(s['wifi_connected']).lower(),
  s['wifi_ssid'].replace(' ','_'),
  str(s['bluetooth_on']).lower(),
  s['screen_brightness'],
  str(s['developer_mode']).lower(),
  str(s['usb_debugging']).lower(),
  str(s['auto_update_off']).lower()
)
" 2>/dev/null || echo "error")"

    # Pass/fail per setting
    local c_sleep c_wifi c_bt c_bright c_dev c_usb c_update c_os c_kagami c_kiosk
    c_sleep=$(check "$stay_awake" "true")
    c_wifi=$(check "$wifi_ok" "true")
    c_bt=$(check "$bt_on" "false")          # want BT OFF
    c_bright=$(check "$brightness" "$WANT_BRIGHTNESS")
    c_dev=$(check "$dev_on" "true")
    c_usb=$(check "$usb_on" "true")
    c_update=$(check "$auto_off" "true")
    c_os=$(check "$os_ver" "$EXPECTED_OS")
    c_kagami=$(check "$kagami_ver" "$EXPECTED_KAGAMI")
    c_kiosk=$(check "$kiosk_ver" "$EXPECTED_KIOSK")

    # Overall pass?
    local all_ok=true
    for c in "$c_sleep" "$c_wifi" "$c_bt" "$c_dev" "$c_usb"; do
      [[ "$c" == "fail" ]] && all_ok=false
    done
    [[ -n "$EXPECTED_OS" && "$c_os" == "fail" ]] && all_ok=false
    [[ -n "$EXPECTED_KAGAMI" && "$c_kagami" == "fail" ]] && all_ok=false
    [[ -n "$EXPECTED_KIOSK" && "$c_kiosk" == "fail" ]] && all_ok=false

    $FAILURES_ONLY && $all_ok && continue

    # Format cells
    fmt_bool() {
      local v="$1" chk="$2"
      if [[ "$chk" == "pass" ]]; then echo -e "$TICK"
      elif [[ "$chk" == "fail" ]]; then echo -e "$CROSS"
      else echo -e "${DIM}?${RESET}"
      fi
    }

    local s_sleep s_wifi s_bt s_bright s_dev s_usb s_update s_ok
    s_sleep=$(fmt_bool "$stay_awake" "$c_sleep")
    s_wifi=$(fmt_bool "$wifi_ok" "$c_wifi")
    s_bt=$(fmt_bool "$bt_on" "$c_bt")
    s_bright=$(fmt_bool "$brightness" "$c_bright")
    s_dev=$(fmt_bool "$dev_on" "$c_dev")
    s_usb=$(fmt_bool "$usb_on" "$c_usb")
    s_update=$(fmt_bool "$auto_off" "$c_update")

    local kagami_disp="$kagami_ver"
    [[ "$kagami_ver" == "MISSING" ]] && kagami_disp="${RED}MISSING${RESET}"
    [[ -n "$EXPECTED_KAGAMI" && "$c_kagami" == "fail" ]] && kagami_disp="${YELLOW}$kagami_ver${RESET}"

    local kiosk_disp="$kiosk_ver"
    [[ "$kiosk_ver" == "MISSING" ]] && kiosk_disp="${RED}MISSING${RESET}"
    [[ -n "$EXPECTED_KIOSK" && "$c_kiosk" == "fail" ]] && kiosk_disp="${YELLOW}$kiosk_ver${RESET}"

    local os_disp="$os_ver"
    [[ -n "$EXPECTED_OS" && "$c_os" == "fail" ]] && os_disp="${YELLOW}$os_ver${RESET}"

    if $all_ok; then
      s_ok="${GREEN}✓${RESET}"
      ((pass_all++)) || true
    else
      s_ok="${RED}✗${RESET}"
      ((fail_count++)) || true
    fi

    printf "%-18s %-8b %-12b %-12b %-7s  %b    %b    %b    %-6s  %b    %b    %b    %b\n" \
      "$ip" "$os_disp" "$kagami_disp" "$kiosk_disp" "$battery" \
      "$s_sleep" "$s_wifi" "$s_bt" "$brightness" \
      "$s_dev" "$s_usb" "$s_update" "$s_ok"
  done

  printf "\n"
  printf "${BOLD}Total: $total   ${GREEN}All-OK: $pass_all${RESET}${BOLD}   ${RED}Issues: $fail_count${RESET}\n"
  printf "Raw data: $RUN_DIR/\n\n"
}

# ── Render CSV ───────────────────────────────────────────────
render_csv() {
  local files=("$RUN_DIR"/*.json)
  echo "ip,os_version,build_id,kagami_version,kagami_installed,kiosk_version,kiosk_installed,battery,stay_awake,wifi_connected,wifi_ssid,bluetooth_on,screen_brightness,developer_mode,usb_debugging,auto_update_off"
  for f in "${files[@]}"; do
    [[ ! -f "$f" ]] && continue
    python3 -c "
import json
d = json.load(open('$f'))
s = d['settings']
k = d['kagami']
ki = d['kiosk']
print(','.join(str(x) for x in [
  d['ip'], d['os_version'], d['build_id'],
  k['version'], k['installed'], ki['version'], ki['installed'], d['battery'],
  s['stay_awake'], s['wifi_connected'], s['wifi_ssid'],
  s['bluetooth_on'], s['screen_brightness'],
  s['developer_mode'], s['usb_debugging'], s['auto_update_off']
]))
" 2>/dev/null
  done
}

# ── Render JSON ──────────────────────────────────────────────
render_json() {
  local files=("$RUN_DIR"/*.json)
  echo "["
  local first=true
  for f in "${files[@]}"; do
    [[ ! -f "$f" ]] && continue
    $first || echo ","
    cat "$f"
    first=false
  done
  echo "]"
}

# ── Main ─────────────────────────────────────────────────────

# Connect to all devices in devices.txt before checking status
if [[ -f "$DEVICES_FILE" ]]; then
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    adb connect "${ip}:5555" &>/dev/null
  done < <(load_devices)
fi

DEVICES=$(online_devices)

if [[ -z "$DEVICES" ]]; then
  echo -e "${RED}No devices online. Check that devices in $DEVICES_FILE are reachable.${RESET}" >&2
  exit 1
fi

COUNT=$(echo "$DEVICES" | wc -l | tr -d ' ')
echo -e "${CYAN}Collecting status from $COUNT device(s)...${RESET} ${DIM}($TOOLKIT_VERSION)${RESET}" >&2

# Parallel collection
PIDS=()
while IFS= read -r serial; do
  [[ -z "$serial" ]] && continue
  collect_device "$serial" &
  PIDS+=($!)
  # Throttle
  while (( ${#PIDS[@]} >= MAX_PARALLEL )); do
    PIDS=($(for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && echo "$p"; done))
    sleep 0.2
  done
done <<< "$DEVICES"
wait "${PIDS[@]}" 2>/dev/null || true

# Auto-fix if requested (runs after collection)
if $AUTO_FIX; then
  echo -e "${YELLOW}Auto-fixing settings on affected devices...${RESET}" >&2
  while IFS= read -r serial; do
    [[ -z "$serial" ]] && continue
    fix_device "$serial" &
  done <<< "$DEVICES"
  wait
  echo ""
fi

# Render output
case "$MODE" in
  table) render_table ;;
  csv)   render_csv ;;
  json)  render_json ;;
esac
