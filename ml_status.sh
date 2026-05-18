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
#   ./ml_status.sh --package com.foo.bar  # override APK to check
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.txt"
STATUS_DIR="$SCRIPT_DIR/status"
MAX_PARALLEL=30

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ---- Check for toolkit updates -------------------------------------
# Requires network — silently skips if offline.
# Hard stops if local repo is behind origin/main.
check_for_updates() {
  if [[ -n "${ML_DEV_TEST:-}" ]]; then
    echo -e "${YELLOW}⚠ ML_DEV_TEST set — update gate bypassed (dev testing only).${RESET}"
    return 0
  fi
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

# ── Resolve active show (read-only — banner to stderr so
#    --json/--csv stdout stays machine-readable) ──────────────
# shellcheck source=lib/show_config.sh
source "$SCRIPT_DIR/lib/show_config.sh"
DEVICES_FILE="$SHOW_DEVICES_FILE"
show_banner >&2

# ── Defaults (show config, overridable via env or args) ──────
TARGET_PACKAGE="${ML_PACKAGE:-$SHOW_PACKAGE}"
KIOSK_PACKAGE="com.tindrum.kiosk"
EXPECTED_OS="${ML_EXPECTED_OS:-$SHOW_EXPECTED_OS}"    # blank skips check
EXPECTED_APK="${ML_EXPECTED_APK:-$SHOW_EXPECTED_APK}"  # blank skips check

# ── Expected settings (pass/fail logic) ─────────────────────
WANT_BRIGHTNESS="0"        # show wants 0; --fix still enforces it, just not shown in the table

# ── Output mode ──────────────────────────────────────────────
MODE="table"   # table | json | csv
FAILURES_ONLY=false
AUTO_FIX=false

TICK="${GREEN}✓${RESET}"; CROSS="${RED}✗${RESET}"

# ── Arg parsing ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)       MODE="json" ;;
    --csv)        MODE="csv" ;;
    --failures)   FAILURES_ONLY=true ;;
    --fix)        AUTO_FIX=true ;;
    --package)    TARGET_PACKAGE="$2"; shift ;;
    --expected-os)  EXPECTED_OS="$2"; shift ;;
    --expected-apk) EXPECTED_APK="$2"; shift ;;
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

  local hw_serial
  hw_serial=$(adb_s getprop ro.serialno)

  local apk_version=""
  local apk_code=""
  if adb -s "$serial" shell pm list packages 2>/dev/null | grep -q "$TARGET_PACKAGE"; then
    apk_version=$(adb_s "dumpsys package $TARGET_PACKAGE" | grep versionName | head -1 | sed 's/.*versionName=//')
    apk_code=$(adb_s "dumpsys package $TARGET_PACKAGE" | grep versionCode | head -1 | sed 's/.*versionCode=//; s/ .*//')
    apk_installed="true"
  else
    apk_installed="false"
  fi

  local kiosk_version=""
  local kiosk_installed="false"
  if adb -s "$serial" shell pm list packages 2>/dev/null | grep -q "$KIOSK_PACKAGE"; then
    kiosk_version=$(adb_s "dumpsys package $KIOSK_PACKAGE" | grep versionName | head -1 | sed 's/.*versionName=//')
    kiosk_installed="true"
  fi

  # ── Settings ─────────────────────────────────────────────
  local stay_awake
  stay_awake=$(adb_s settings get global stay_on_while_plugged_in)
  # ML2: value 3 = stay awake on AC+USB, 1 = AC only, 0 = off
  # Normalize: any non-zero = awake
  [[ "$stay_awake" == "null" || "$stay_awake" == "" ]] && stay_awake="0"
  local stay_awake_on="false"
  [[ "$stay_awake" != "0" ]] && stay_awake_on="true"

  # Same pipefail trap as BT below: piping slow `adb dumpsys wifi`
  # into head/grep makes the pipeline fail on SIGPIPE, and the old
  # `|| echo ""` then blanked the SSID so connected devices read
  # offline. Capture first, then parse the in-memory string.
  local wifi_dump wifi_ssid=""
  wifi_dump=$(adb_s "dumpsys wifi")
  wifi_ssid=$(printf '%s\n' "$wifi_dump" | grep -m1 'mWifiInfo' | grep -o 'SSID: [^,]*' | head -1 | sed 's/SSID: //' | tr -d '"' || true)
  local wifi_connected="false"
  [[ -n "$wifi_ssid" && "$wifi_ssid" != "<unknown ssid>" ]] && wifi_connected="true"

  # `settings global bluetooth_on` only reflects what was written to
  # that key, not the radio — on the 1.4.1 user build a device with BT
  # enabled via the headset UI / pairing still reads 0. dumpsys
  # bluetooth_manager tracks the real adapter state.
  # NB: capture, then match — piping a large dumpsys into `grep -q`
  # under `set -o pipefail` makes grep close the pipe on first match,
  # adb dies with SIGPIPE, and the pipeline reports failure even on a
  # match — which silently reports every device's BT as off.
  local bt_dump bt_on="false"
  bt_dump=$(adb_s "dumpsys bluetooth_manager")
  case "$bt_dump" in
    *curState=OnState*|*"enabled: true"*) bt_on="true" ;;
  esac

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
  "hw_serial": "$hw_serial",
  "ip": "${serial%%:*}",
  "timestamp": "$TIMESTAMP",
  "os_version": "$os_version",
  "build_id": "$build_id",
  "battery": "$battery",
  "apk": {
    "package": "$TARGET_PACKAGE",
    "installed": $apk_installed,
    "version": "$apk_version",
    "version_code": "$apk_code"
  },
  "kiosk": {
    "package": "$KIOSK_PACKAGE",
    "installed": $kiosk_installed,
    "version": "$kiosk_version"
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
  [[ "$bt_on" == "false" ]] && adb -s "$serial" shell svc bluetooth enable 2>/dev/null || true

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
  printf "${BOLD}%-18s %-8s %-10s %-10s %-8s  %s  %s  %s  %s  %s  %s  %s${RESET}\n" \
    "IP" "OS" "Kagami" "Kiosk" "Batt%" "Sleep" "WiFi" "BT" "Dev" "USB" "NoUpd" "OK?"
  printf "%-18s %-8s %-10s %-10s %-8s  %s  %s  %s  %s  %s  %s  %s\n" \
    "──────────────────" "────────" "──────────" "──────────" "───────" "─────" "─────" "─────" "─────" "─────" "─────" "───"

  for f in "${files[@]}"; do
    [[ ! -f "$f" ]] && continue
    ((total++)) || true

    # Parse JSON with python3 (available on macOS)
    read -r ip os_ver apk_ver kiosk_ver battery stay_awake wifi_ok wifi_ssid bt_on brightness dev_on usb_on auto_off <<< \
      "$(python3 -c "
import json, sys
d = json.load(open('$f'))
s = d['settings']
print(
  d['ip'],
  d['os_version'],
  d['apk']['version'] if d['apk']['installed'] else 'MISSING',
  d.get('kiosk', {}).get('version', '') if d.get('kiosk', {}).get('installed') else 'MISSING',
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
    local c_sleep c_wifi c_bt c_bright c_dev c_usb c_update c_os c_apk
    c_sleep=$(check "$stay_awake" "true")
    c_wifi=$(check "$wifi_ok" "true")
    c_bt=$(check "$bt_on" "true")           # want BT ON — controllers need it
    # shellcheck disable=SC2034  # c_bright used only in auto-fix path
    c_bright=$(check "$brightness" "$WANT_BRIGHTNESS")
    c_dev=$(check "$dev_on" "true")
    c_usb=$(check "$usb_on" "true")
    c_update=$(check "$auto_off" "true")
    c_os=$(check "$os_ver" "$EXPECTED_OS")
    c_apk=$(check "$apk_ver" "$EXPECTED_APK")

    # Overall pass?
    local all_ok=true
    for c in "$c_sleep" "$c_wifi" "$c_bt" "$c_dev" "$c_usb"; do
      [[ "$c" == "fail" ]] && all_ok=false
    done
    [[ "$apk_ver" == "MISSING" ]] && all_ok=false
    [[ "$kiosk_ver" == "MISSING" ]] && all_ok=false
    [[ -n "$EXPECTED_OS" && "$c_os" == "fail" ]] && all_ok=false
    [[ -n "$EXPECTED_APK" && "$c_apk" == "fail" ]] && all_ok=false

    $FAILURES_ONLY && $all_ok && continue

    # Format cells
    fmt_bool() {
      local chk="$2"
      if [[ "$chk" == "pass" ]]; then echo -e "$TICK"
      elif [[ "$chk" == "fail" ]]; then echo -e "$CROSS"
      else echo -e "${DIM}?${RESET}"
      fi
    }

    local s_sleep s_wifi s_bt s_dev s_usb s_update s_ok
    s_sleep=$(fmt_bool "$stay_awake" "$c_sleep")
    s_wifi=$(fmt_bool "$wifi_ok" "$c_wifi")
    s_bt=$(fmt_bool "$bt_on" "$c_bt")
    s_dev=$(fmt_bool "$dev_on" "$c_dev")
    s_usb=$(fmt_bool "$usb_on" "$c_usb")
    s_update=$(fmt_bool "$auto_off" "$c_update")

    local apk_disp="$apk_ver"
    [[ "$apk_ver" == "MISSING" ]] && apk_disp="${RED}MISSING${RESET}"
    [[ -n "$EXPECTED_APK" && "$c_apk" == "fail" ]] && apk_disp="${YELLOW}$apk_ver${RESET}"

    local kiosk_disp="$kiosk_ver"
    [[ "$kiosk_ver" == "MISSING" ]] && kiosk_disp="${RED}MISSING${RESET}"

    local os_disp="$os_ver"
    [[ -n "$EXPECTED_OS" && "$c_os" == "fail" ]] && os_disp="${YELLOW}$os_ver${RESET}"

    if $all_ok; then
      s_ok="${GREEN}✓${RESET}"
      ((pass_all++)) || true
    else
      s_ok="${RED}✗${RESET}"
      ((fail_count++)) || true
    fi

    printf "%-18s %-8b %-10b %-10b %-7s%%  %b    %b    %b    %b    %b    %b    %b\n" \
      "$ip" "$os_disp" "$apk_disp" "$kiosk_disp" "$battery" \
      "$s_sleep" "$s_wifi" "$s_bt" \
      "$s_dev" "$s_usb" "$s_update" "$s_ok"
  done

  printf "\n"
  printf "${BOLD}Total: $total   ${GREEN}All-OK: $pass_all${RESET}${BOLD}   ${RED}Issues: $fail_count${RESET}\n"
  printf "Raw data: $RUN_DIR/\n\n"
}

# ── Render CSV ───────────────────────────────────────────────
render_csv() {
  local files=("$RUN_DIR"/*.json)
  echo "ip,os_version,build_id,apk_version,apk_installed,battery,stay_awake,wifi_connected,wifi_ssid,bluetooth_on,screen_brightness,developer_mode,usb_debugging,auto_update_off"
  for f in "${files[@]}"; do
    [[ ! -f "$f" ]] && continue
    python3 -c "
import json
d = json.load(open('$f'))
s = d['settings']
a = d['apk']
print(','.join(str(x) for x in [
  d['ip'], d['os_version'], d['build_id'],
  a['version'], a['installed'], d['battery'],
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
DEVICES=$(online_devices)

if [[ -z "$DEVICES" ]]; then
  echo -e "${RED}No devices online. Run: ./ml_deploy.sh connect${RESET}" >&2
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
    mapfile -t PIDS < <(for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
    sleep 0.2
  done
done <<< "$DEVICES"
wait "${PIDS[@]}" 2>/dev/null || true

# Auto-fix if requested (runs after collection)
if $AUTO_FIX; then
  echo -e "${YELLOW}Auto-fixing settings on affected devices...${RESET}"
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
