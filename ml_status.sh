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

# bash 5+ required (macOS default 3.2 lacks mapfile et al.) — hard-stop early
source "$(dirname "${BASH_SOURCE[0]}")/lib/require_bash5.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.txt"
STATUS_DIR="$SCRIPT_DIR/status"
# Per-device collection does ~20 adb calls each; at high parallelism through one
# adb server those collide and return blank (devices silently dropped at ~90+
# scale). 8 is the sweet spot that held; override with ML_STATUS_PARALLEL.
MAX_PARALLEL="${ML_STATUS_PARALLEL:-8}"
# Light reachability probe can run wider than collection.
PROBE_PARALLEL="${ML_PROBE_PARALLEL:-48}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ---- Check for toolkit updates -------------------------------------
# Requires network — silently skips if offline.
# Hard stops if local repo is behind origin/main.
check_for_updates() {
  if [[ -n "${ML_DEV_TEST:-}" ]]; then
    echo -e "${YELLOW}⚠ ML_DEV_TEST set — update gate bypassed (dev testing only).${RESET}" >&2
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
EXPECTED_KIOSK="${ML_KIOSK_VERSION:-$SHOW_KIOSK_VERSION}"  # blank skips exact (drift) check
EXPECTED_KIOSK_SUFFIX="${ML_KIOSK_SUFFIX:-$SHOW_KIOSK_SUFFIX}"  # show-marker r/b; blank skips wrong-show check

# ── Expected settings (pass/fail logic) ─────────────────────
# Brightness comes from the active show's shows/<id>.conf
# (SHOW_BRIGHTNESS). Override via env for one-off runs only.
WANT_BRIGHTNESS="${ML_BRIGHTNESS:-$SHOW_BRIGHTNESS}"

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
  grep -vE '^[[:space:]]*(#|$)' "$DEVICES_FILE" 2>/dev/null || true
}

online_devices() {
  adb devices | grep -v "List of" | grep "device$" | awk '{print $1}' || true
}

# ── Collect data from a single device ────────────────────────
collect_device() {
  # Always invoked backgrounded (`collect_device &`), so this runs in its own
  # subshell — disable errexit HERE so a blank/partial adb read (a no-match
  # grep under pipefail) can't abort the job before it writes its record. That
  # silent mid-function abort was dropping devices from the count at scale.
  # The function gathers best-effort (blank fields where a read fails) and
  # always writes one JSON. Total then reconciles with the device count.
  set +e +o pipefail
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

  # Connected-but-blank guard: if the two cheapest reads both come back empty,
  # the device answered the TCP connect but its shell isn't responding (adb
  # contention, or handshake not settled). Retry once; if still blank, emit an
  # ERROR record instead of silently producing a junk/empty row (the old
  # behavior dropped these from the count entirely).
  if [[ -z "$os_version" && -z "$hw_serial" ]]; then
    sleep 0.5
    os_version=$(adb_s getprop ro.build.version.lumin)
    hw_serial=$(adb_s getprop ro.serialno)
    if [[ -z "$os_version" && -z "$hw_serial" ]]; then
      emit_error "${serial%:5555}" "connected but no shell response (adb contention?)"
      return
    fi
  fi

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

  local hand_nav_val hand_nav_on="false"
  hand_nav_val=$(adb_s settings get system enable_pinch_gesture_inputs)
  [[ "$hand_nav_val" == "1" ]] && hand_nav_on="true"

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

  # ADB auth timeout: 0 = disabled (never expire). Unset/non-zero = Android's
  # default ~7-day revoke, which silently de-authorizes the fleet after a week
  # of no connection. Tracked so --fix can disable it. See ml_provision.sh.
  local adb_auth_to
  adb_auth_to=$(adb_s settings get global adb_allowed_connection_time)
  [[ "$adb_auth_to" == "null" || "$adb_auth_to" == "" ]] && adb_auth_to="default"
  local adb_auth_timeout_off="false"
  [[ "$adb_auth_to" == "0" ]] && adb_auth_timeout_off="true"

  # ML2 uses OTA update system — check if auto-update is suppressed
  local auto_update
  auto_update=$(adb_s settings get global auto_update_enabled 2>/dev/null || echo "")
  [[ -z "$auto_update" || "$auto_update" == "null" ]] && auto_update=$(adb_s getprop persist.sys.ota.update.disable 2>/dev/null || echo "")
  local auto_update_off="false"
  [[ "$auto_update" == "0" || "$auto_update" == "1" && "$(adb_s getprop persist.sys.ota.update.disable)" == "1" ]] && auto_update_off="true"
  # Fallback: if property not set, mark as unknown
  [[ -z "$auto_update" || "$auto_update" == "null" ]] && auto_update="unknown" && auto_update_off="unknown"

  # ── Battery + charging (one dumpsys, two values) ─────────
  local battery_dump charging="false" battery="0"
  battery_dump=$(adb_s "dumpsys battery")
  battery=$(printf '%s\n' "$battery_dump" | grep -m1 '  level:' | awk '{print $2}')
  [[ -z "$battery" ]] && battery="0"
  case "$battery_dump" in
    *"AC powered: true"*|*"USB powered: true"*|*"Wireless powered: true"*) charging="true" ;;
  esac

  # ── /sdcard disk usage ───────────────────────────────────
  # busybox df: Filesystem 1K-blocks Used Available Use% Mounted-on
  local df_line disk_total_kb=0 disk_used_kb=0 disk_avail_kb=0 disk_used_pct=0
  df_line=$(adb_s "df /sdcard" | tail -1)
  if [[ -n "$df_line" ]]; then
    disk_total_kb=$(echo "$df_line" | awk '{print $2}')
    disk_used_kb=$(echo "$df_line" | awk '{print $3}')
    disk_avail_kb=$(echo "$df_line" | awk '{print $4}')
    disk_used_pct=$(echo "$df_line" | awk '{print $5}' | tr -d '%')
    [[ -z "$disk_total_kb" || ! "$disk_total_kb" =~ ^[0-9]+$ ]] && disk_total_kb=0
    [[ -z "$disk_used_kb"  || ! "$disk_used_kb"  =~ ^[0-9]+$ ]] && disk_used_kb=0
    [[ -z "$disk_avail_kb" || ! "$disk_avail_kb" =~ ^[0-9]+$ ]] && disk_avail_kb=0
    [[ -z "$disk_used_pct" || ! "$disk_used_pct" =~ ^[0-9]+$ ]] && disk_used_pct=0
  fi

  # ── Show data dir contents ───────────────────────────────
  # /sdcard/$SHOW_DATA_DIR/ may contain:
  #  - required entries (SHOW_DATA_REQUIRED) — missing any of these
  #    is dashboard trouble. Typically just "data" (the assets the
  #    SSD-copy step lands).
  #  - optional entries (SHOW_DATA_OPTIONAL) — files/dirs the show
  #    APK creates at runtime (logs, textures, apriltag config).
  #    Absence is fine; a bench-fresh device just hasn't run yet.
  #  - extraneous: anything not in either set, including the
  #    pathological /sdcard/$SHOW_DATA_DIR/data/data recursion.
  local data_root="/sdcard/$SHOW_DATA_DIR"
  local data_root_exists="false"
  local -a data_present=() data_missing=() data_extra=()
  local -a req_arr=() opt_arr=()
  read -ra req_arr <<< "$SHOW_DATA_REQUIRED"
  read -ra opt_arr <<< "$SHOW_DATA_OPTIONAL"
  # Matching is case-INSENSITIVE: ML2 /sdcard resolves paths
  # case-insensitively (data == Data == DATA → same dir, confirmed on
  # 1.4.1), so a dir stored as `Data` satisfies a required `data` and
  # must NOT be flagged extraneous — the device reads it fine either
  # way. Hence `grep -qix` for presence and lowercased `==` for the
  # extraneous classification below.
  if [[ "$(adb_s "[ -d $data_root ] && echo yes")" == "yes" ]]; then
    data_root_exists="true"
    local listing
    listing=$(adb_s "ls -1 $data_root")
    local entry e found
    # Missing: required entries that are absent OR exist as
    # empty directories. An empty `data/` is effectively missing
    # — the SSD copy hasn't landed, even though the dir is there.
    # `ls -A` lists hidden + non-hidden; empty output means empty.
    for e in "${req_arr[@]}"; do
      if printf '%s\n' "$listing" | grep -qix "$e"; then
        if [[ "$(adb_s "[ -d $data_root/$e ] && echo dir")" == "dir" ]]; then
          local inner; inner=$(adb_s "ls -A $data_root/$e")
          if [[ -n "$inner" ]]; then
            data_present+=("$e")
          else
            data_missing+=("$e (empty)")
          fi
        else
          # Required entry exists as a file (e.g. config.json if a
          # show ever puts a file in required) — just having it
          # counts as present.
          data_present+=("$e")
        fi
      else
        data_missing+=("$e")
      fi
    done
    # Also record any optional entries that ARE present (for visibility)
    for e in "${opt_arr[@]}"; do
      printf '%s\n' "$listing" | grep -qix "$e" && data_present+=("$e")
    done
    # Extraneous: actual entries not in (required ∪ optional)
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      found=false
      for e in "${req_arr[@]}"; do
        [[ "${entry,,}" == "${e,,}" ]] && found=true && break
      done
      if ! $found; then
        for e in "${opt_arr[@]}"; do
          [[ "${entry,,}" == "${e,,}" ]] && found=true && break
        done
      fi
      $found || data_extra+=("$entry")
    done <<< "$listing"
    if [[ "$(adb_s "[ -d $data_root/data/data ] && echo yes")" == "yes" ]]; then
      data_extra+=("data/data")
    fi
  else
    data_missing=("${req_arr[@]+"${req_arr[@]}"}")
  fi

  # ── com.tindrum.* packages ───────────────────────────────
  local tindrum_raw
  tindrum_raw=$(adb_s "pm list packages com.tindrum" | sed 's/^package://' | sort)
  local -a tindrum_all=() tindrum_extra=()
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    tindrum_all+=("$p")
    if [[ "$p" != "$TARGET_PACKAGE" && "$p" != "$KIOSK_PACKAGE" ]]; then
      tindrum_extra+=("$p")
    fi
  done <<< "$tindrum_raw"

  # ── JSON helpers ─────────────────────────────────────────
  _json_strarr() {
    if [[ $# -eq 0 ]]; then
      printf '[]'
    else
      python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"
    fi
  }
  local present_json missing_json extra_json required_json optional_json all_pkg_json extra_pkg_json
  present_json=$(_json_strarr   "${data_present[@]+"${data_present[@]}"}")
  missing_json=$(_json_strarr   "${data_missing[@]+"${data_missing[@]}"}")
  extra_json=$(_json_strarr     "${data_extra[@]+"${data_extra[@]}"}")
  required_json=$(_json_strarr  "${req_arr[@]+"${req_arr[@]}"}")
  optional_json=$(_json_strarr  "${opt_arr[@]+"${opt_arr[@]}"}")
  all_pkg_json=$(_json_strarr   "${tindrum_all[@]+"${tindrum_all[@]}"}")
  extra_pkg_json=$(_json_strarr "${tindrum_extra[@]+"${tindrum_extra[@]}"}")

  # ── Write JSON ───────────────────────────────────────────
  cat > "$out" <<EOF
{
  "serial": "$serial",
  "hw_serial": "$hw_serial",
  "ip": "${serial%%:*}",
  "online": true,
  "timestamp": "$TIMESTAMP",
  "os_version": "$os_version",
  "expected_os": "$EXPECTED_OS",
  "build_id": "$build_id",
  "battery": "$battery",
  "charging": $charging,
  "apk": {
    "package": "$TARGET_PACKAGE",
    "installed": $apk_installed,
    "version": "$apk_version",
    "version_code": "$apk_code",
    "expected_version": "$EXPECTED_APK"
  },
  "kiosk": {
    "package": "$KIOSK_PACKAGE",
    "installed": $kiosk_installed,
    "version": "$kiosk_version",
    "expected_version": "$EXPECTED_KIOSK",
    "expected_suffix": "$EXPECTED_KIOSK_SUFFIX"
  },
  "disk": {
    "mount": "/sdcard",
    "total_kb": $disk_total_kb,
    "used_kb": $disk_used_kb,
    "available_kb": $disk_avail_kb,
    "used_pct": $disk_used_pct,
    "warn_pct": $SHOW_DISK_WARN_PCT
  },
  "data": {
    "root": "$data_root",
    "root_exists": $data_root_exists,
    "required": $required_json,
    "optional": $optional_json,
    "present": $present_json,
    "missing": $missing_json,
    "extraneous": $extra_json
  },
  "packages": {
    "tindrum_all": $all_pkg_json,
    "extraneous_tindrum": $extra_pkg_json
  },
  "settings": {
    "stay_awake": $stay_awake_on,
    "stay_awake_raw": "$stay_awake",
    "wifi_connected": $wifi_connected,
    "wifi_ssid": "$wifi_ssid",
    "bluetooth_on": $bt_on,
    "screen_brightness": $brightness,
    "hand_nav_on": $hand_nav_on,
    "developer_mode": $dev_on,
    "usb_debugging": $usb_on,
    "adb_auth_timeout_off": $adb_auth_timeout_off,
    "adb_auth_timeout_raw": "$adb_auth_to",
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

  # Brightness. Force adaptive/auto-brightness OFF first — otherwise
  # ML2 recomputes screen_brightness from ambient light and the written
  # value never sticks (field: devices drifted back to ~50%). Mirrors
  # what ml_provision.sh sets. screen_brightness_mode is not a status
  # table column; --fix enforces it anyway — drift is corrected even
  # when it isn't displayed. Unconditional + idempotent.
  adb_set system screen_brightness_mode 0
  local brightness
  brightness=$(python3 -c "import json,sys; d=json.load(open('$data_file')); print(d['settings']['screen_brightness'])" 2>/dev/null)
  [[ -n "$WANT_BRIGHTNESS" && "$brightness" != "$WANT_BRIGHTNESS" ]] && \
    adb_set system screen_brightness "$WANT_BRIGHTNESS"

  # Disable the adb auth timeout so this laptop's authorization never expires.
  # Android's default ~7-day revoke is what silently de-authorized the fleet
  # after it shipped unconnected. 0 = never expire. Compare the raw value (a
  # string) to sidestep Python True/False casing. Idempotent.
  local adb_to_raw
  adb_to_raw=$(python3 -c "import json,sys; d=json.load(open('$data_file')); print(d['settings']['adb_auth_timeout_raw'])" 2>/dev/null)
  [[ "$adb_to_raw" != "0" ]] && adb_set global adb_allowed_connection_time 0

  echo "  Fixed: $serial"
}
export -f fix_device 2>/dev/null || true

# ── Emit a stub for a device that's reachable but unreadable ──
# Port was open and adb connected, but shell reads came back blank (contention
# or unstable session). online:true + error:true so it's counted and visibly
# flagged, never silently dropped.
emit_error() {
  local ip="$1" why="${2:-unreadable}"
  local serial="${ip}:5555"
  local out="$RUN_DIR/${serial//:/_}.json"
  cat > "$out" <<EOF
{
  "serial": "$serial",
  "hw_serial": "",
  "ip": "$ip",
  "online": true,
  "error": "$why",
  "timestamp": "$TIMESTAMP",
  "os_version": "",
  "expected_os": "$EXPECTED_OS",
  "build_id": "",
  "battery": "0",
  "charging": false,
  "apk": { "package": "$TARGET_PACKAGE", "installed": false, "version": "", "version_code": "", "expected_version": "$EXPECTED_APK" },
  "kiosk": { "package": "$KIOSK_PACKAGE", "installed": false, "version": "", "expected_version": "$EXPECTED_KIOSK", "expected_suffix": "$EXPECTED_KIOSK_SUFFIX" },
  "disk": { "mount": "/sdcard", "total_kb": 0, "used_kb": 0, "available_kb": 0, "used_pct": 0, "warn_pct": $SHOW_DISK_WARN_PCT },
  "data": { "root": "/sdcard/$SHOW_DATA_DIR", "root_exists": null, "required": [], "optional": [], "present": [], "missing": [], "extraneous": [] },
  "packages": { "tindrum_all": [], "extraneous_tindrum": [] },
  "settings": { "stay_awake": false, "stay_awake_raw": "", "wifi_connected": false, "wifi_ssid": "", "bluetooth_on": false, "screen_brightness": 0, "hand_nav_on": null, "developer_mode": false, "usb_debugging": false, "auto_update_off": "unknown" }
}
EOF
}
export -f emit_error 2>/dev/null || true

# ── Emit a stub record for an EXPECTED-but-OFFLINE device ─────
# A device in the show's device list that isn't reachable over adb
# never gets collected — historically it just vanished from the
# dashboard, which is the worst trouble to hide. Write a minimal
# record (online:false) so it surfaces as OFFLINE. We only know its
# IP; the dashboard backfills device #/serial from its last-seen cache.
emit_offline() {
  local ip="$1"
  local serial="${ip}:5555"
  local out="$RUN_DIR/${serial//:/_}.json"
  cat > "$out" <<EOF
{
  "serial": "$serial",
  "hw_serial": "",
  "ip": "$ip",
  "online": false,
  "timestamp": "$TIMESTAMP",
  "os_version": "",
  "expected_os": "$EXPECTED_OS",
  "build_id": "",
  "battery": "0",
  "charging": false,
  "apk": { "package": "$TARGET_PACKAGE", "installed": false, "version": "", "version_code": "", "expected_version": "$EXPECTED_APK" },
  "kiosk": { "package": "$KIOSK_PACKAGE", "installed": false, "version": "", "expected_version": "$EXPECTED_KIOSK", "expected_suffix": "$EXPECTED_KIOSK_SUFFIX" },
  "disk": { "mount": "/sdcard", "total_kb": 0, "used_kb": 0, "available_kb": 0, "used_pct": 0, "warn_pct": $SHOW_DISK_WARN_PCT },
  "data": { "root": "/sdcard/$SHOW_DATA_DIR", "root_exists": null, "required": [], "optional": [], "present": [], "missing": [], "extraneous": [] },
  "packages": { "tindrum_all": [], "extraneous_tindrum": [] },
  "settings": { "stay_awake": false, "stay_awake_raw": "", "wifi_connected": false, "wifi_ssid": "", "bluetooth_on": false, "screen_brightness": 0, "hand_nav_on": null, "developer_mode": false, "usb_debugging": false, "auto_update_off": "unknown" }
}
EOF
}

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
  local total=0 pass_all=0 fail_count=0 offline_count=0 error_count=0

  # Header
  printf "\n"
  printf "${BOLD}%-18s %-8s %-10s %-10s %-8s  %s  %s  %s  %s  %s  %s  %s${RESET}\n" \
    "IP" "OS" "Kagami" "Kiosk" "Batt%" "Sleep" "WiFi" "BT" "Dev" "USB" "NoUpd" "OK?"
  printf "%-18s %-8s %-10s %-10s %-8s  %s  %s  %s  %s  %s  %s  %s\n" \
    "──────────────────" "────────" "──────────" "──────────" "───────" "─────" "─────" "─────" "─────" "─────" "─────" "───"

  for f in "${files[@]}"; do
    [[ ! -f "$f" ]] && continue
    ((total++)) || true

    # Offline stub (online:false) — short-circuit before the heavy
    # per-field parse and print a clear OFFLINE row.
    if [[ "$(python3 -c "import json;print(json.load(open('$f')).get('online',True))" 2>/dev/null)" == "False" ]]; then
      ((offline_count++)) || true
      local oip; oip=$(python3 -c "import json;print(json.load(open('$f'))['ip'])" 2>/dev/null)
      printf "%-18s ${RED}%s${RESET}\n" "$oip" "OFFLINE — in device list but unreachable"
      continue
    fi

    # Error stub (online:true + error) — reachable but unreadable (adb
    # contention / unstable session). Surfaced, never silently dropped.
    local errmsg; errmsg=$(python3 -c "import json;print(json.load(open('$f')).get('error',''))" 2>/dev/null)
    if [[ -n "$errmsg" ]]; then
      ((error_count++)) || true
      local eip; eip=$(python3 -c "import json;print(json.load(open('$f'))['ip'])" 2>/dev/null)
      printf "%-18s ${YELLOW}%s${RESET}\n" "$eip" "ERROR — $errmsg (re-run; lower ML_STATUS_PARALLEL if persistent)"
      continue
    fi

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
    local c_sleep c_wifi c_bt c_bright c_dev c_usb c_update c_os c_apk c_kiosk c_kiosk_suffix
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
    c_kiosk=$(check "$kiosk_ver" "$EXPECTED_KIOSK")
    # Kiosk show-marker: versionName must END WITH this show's suffix (r/b).
    # Independent of the (blank-able) exact version check, so a wrong-show kiosk
    # is caught even during build churn when SHOW_KIOSK_VERSION is blank.
    c_kiosk_suffix="skip"
    if [[ -n "$EXPECTED_KIOSK_SUFFIX" && "$kiosk_ver" != "MISSING" ]]; then
      if [[ "$kiosk_ver" == *"$EXPECTED_KIOSK_SUFFIX" ]]; then c_kiosk_suffix="pass"; else c_kiosk_suffix="fail"; fi
    fi

    # Overall pass?
    local all_ok=true
    for c in "$c_sleep" "$c_wifi" "$c_bt" "$c_dev" "$c_usb"; do
      [[ "$c" == "fail" ]] && all_ok=false
    done
    [[ "$apk_ver" == "MISSING" ]] && all_ok=false
    [[ "$kiosk_ver" == "MISSING" ]] && all_ok=false
    [[ -n "$EXPECTED_OS" && "$c_os" == "fail" ]] && all_ok=false
    [[ -n "$EXPECTED_APK" && "$c_apk" == "fail" ]] && all_ok=false
    [[ -n "$EXPECTED_KIOSK" && "$kiosk_ver" != "MISSING" && "$c_kiosk" == "fail" ]] && all_ok=false
    [[ "$c_kiosk_suffix" == "fail" ]] && all_ok=false   # wrong-show kiosk

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

    # Build width-correct version/OS cells. KEY FIX: pad the PLAIN text to the
    # column width FIRST, then wrap color — so ANSI escape codes never count
    # toward the field width (that miscount smeared every column to the right of
    # a colored/failing cell). mkcell emits real escapes + padded text; the row
    # then prints the prebuilt cells with %s.
    mkcell() { local t="$1" w="$2" c="${3:-}" p; printf -v p "%-${w}s" "$t"; [[ -n "$c" ]] && printf '%b%s%b' "$c" "$p" "$RESET" || printf '%s' "$p"; }

    local os_color="" apk_text="$apk_ver" apk_color="" kiosk_text="$kiosk_ver" kiosk_color=""
    [[ -n "$EXPECTED_OS" && "$c_os" == "fail" ]] && os_color="$YELLOW"
    if [[ "$apk_ver" == "MISSING" ]]; then apk_text="MISSING"; apk_color="$RED"
    elif [[ -n "$EXPECTED_APK" && "$c_apk" == "fail" ]]; then apk_color="$YELLOW"; fi
    if [[ "$kiosk_ver" == "MISSING" ]]; then kiosk_text="MISSING"; kiosk_color="$RED"
    elif [[ "$c_kiosk_suffix" == "fail" ]]; then kiosk_color="$RED"        # wrong-show: red version
    elif [[ -n "$EXPECTED_KIOSK" && "$c_kiosk" == "fail" ]]; then kiosk_color="$YELLOW"; fi

    local os_cell apk_cell kiosk_cell batt_disp="${battery}%"
    os_cell=$(mkcell "$os_ver" 8 "$os_color")
    apk_cell=$(mkcell "$apk_text" 10 "$apk_color")
    kiosk_cell=$(mkcell "$kiosk_text" 10 "$kiosk_color")

    if $all_ok; then
      s_ok="${GREEN}✓${RESET}"
      ((pass_all++)) || true
    else
      s_ok="${RED}✗${RESET}"
      ((fail_count++)) || true
    fi

    printf "%-18s %s %s %s %-8s  %b    %b    %b    %b    %b    %b    %b\n" \
      "$ip" "$os_cell" "$apk_cell" "$kiosk_cell" "$batt_disp" \
      "$s_sleep" "$s_wifi" "$s_bt" \
      "$s_dev" "$s_usb" "$s_update" "$s_ok"
  done

  printf "\n"
  printf "${BOLD}Total: $total   ${GREEN}All-OK: $pass_all${RESET}${BOLD}   ${RED}Issues: $fail_count   ${YELLOW}Error: $error_count   ${RED}Offline: $offline_count${RESET}\n"
  printf "${DIM}(Total should equal the device-list count: OK + Issues + Error + Offline)${RESET}\n"
  printf "Raw data: $RUN_DIR/\n\n"
}

# ── Render CSV ───────────────────────────────────────────────
# Columns mirror what the table + JSON expose (offline stubs, kiosk
# versionName, data-dir contents, disk usage, hand nav, charging), so
# operators importing CSV into a spreadsheet get the same picture as
# the dashboard. Header order matches the print() below.
render_csv() {
  local files=("$RUN_DIR"/*.json)
  echo "ip,online,hw_serial,os_version,build_id,apk_version,apk_installed,kiosk_version,kiosk_installed,battery,charging,disk_used_pct,stay_awake,wifi_connected,wifi_ssid,bluetooth_on,screen_brightness,hand_nav_on,developer_mode,usb_debugging,auto_update_off,data_missing_count,data_extra_count"
  for f in "${files[@]}"; do
    [[ ! -f "$f" ]] && continue
    python3 -c "
import json
d = json.load(open('$f'))
s = d['settings']
a = d['apk']
k = d.get('kiosk', {})
disk = d.get('disk', {})
data = d.get('data', {})
print(','.join(str(x) for x in [
  d['ip'], d.get('online', True), d.get('hw_serial', ''),
  d['os_version'], d['build_id'],
  a['version'], a['installed'],
  k.get('version', ''), k.get('installed', False),
  d['battery'], d.get('charging', False),
  disk.get('used_pct', 0),
  s['stay_awake'], s['wifi_connected'], s['wifi_ssid'],
  s['bluetooth_on'], s['screen_brightness'], s.get('hand_nav_on', ''),
  s['developer_mode'], s['usb_debugging'], s['auto_update_off'],
  len(data.get('missing', [])), len(data.get('extraneous', []))
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
# Start from a CLEAN adb table. A polluted table (stale offline entries from
# prior scans/connects) makes shell reads return blank, dropping devices.
# Skip with ML_NO_KILLSERVER=1 if other adb work is in flight.
if [[ -z "${ML_NO_KILLSERVER:-}" ]]; then
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true
fi

# Work list = the EXPECTED device file, NOT adb's connection table (which decays
# between runs → the old false-OFFLINE / "0 online" bug). Probe each IP's port
# in parallel, adb-connect the responders so they handshake to "device" state,
# then collect those; non-responders are genuinely offline. Every expected IP
# yields exactly one record (full / ERROR / OFFLINE), so the totals reconcile.
EXPECTED=$(load_devices | tr -d ' \t\r' | grep . || true)
if [[ -z "$EXPECTED" ]]; then
  echo -e "${RED}No devices in $(basename "$DEVICES_FILE").${RESET}" >&2
  exit 1
fi
EXP_COUNT=$(printf '%s\n' "$EXPECTED" | grep -c . || true)

echo -e "${CYAN}Probing $EXP_COUNT device(s) [parallel $PROBE_PARALLEL]...${RESET} ${DIM}($TOOLKIT_VERSION)${RESET}" >&2
ALIVE_DIR=$(mktemp -d)
PIDS=()
while IFS= read -r ip; do
  [[ -z "$ip" ]] && continue
  {
    if nc -z -G 2 -w 2 "$ip" 5555 >/dev/null 2>&1; then
      adb connect "${ip}:5555" >/dev/null 2>&1 || true
      echo "$ip" > "$ALIVE_DIR/$ip"
    fi
  } &
  PIDS+=($!)
  while (( ${#PIDS[@]} >= PROBE_PARALLEL )); do
    mapfile -t PIDS < <(for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
    sleep 0.1
  done
done <<< "$EXPECTED"
wait 2>/dev/null || true
sleep 1   # let fresh connects settle to "device" state before shell reads

ALIVE=$(ls "$ALIVE_DIR" 2>/dev/null || true)
ALIVE_COUNT=$(printf '%s\n' "$ALIVE" | grep -c . || true)
echo -e "${CYAN}Collecting from $ALIVE_COUNT reachable device(s) [parallel $MAX_PARALLEL]...${RESET}" >&2

# Phase 2: collect reachable devices (bounded — low parallelism avoids the
# adb-server contention that returned blank reads at ~90+ devices).
PIDS=()
while IFS= read -r ip; do
  [[ -z "$ip" ]] && continue
  collect_device "${ip}:5555" &
  PIDS+=($!)
  while (( ${#PIDS[@]} >= MAX_PARALLEL )); do
    mapfile -t PIDS < <(for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && echo "$p"; done)
    sleep 0.2
  done
done <<< "$ALIVE"
wait 2>/dev/null || true

# Offline stubs for expected devices that didn't answer the port probe.
OFFLINE_COUNT=0
while IFS= read -r ip; do
  [[ -z "$ip" ]] && continue
  if [[ ! -e "$ALIVE_DIR/$ip" ]]; then
    emit_offline "$ip"
    OFFLINE_COUNT=$((OFFLINE_COUNT+1))
  fi
done <<< "$EXPECTED"
rm -rf "$ALIVE_DIR"
[[ "$OFFLINE_COUNT" -gt 0 ]] && \
  echo -e "${YELLOW}⚠ $OFFLINE_COUNT device(s) offline (no port-5555 response).${RESET}" >&2

# Auto-fix if requested (runs after collection)
if $AUTO_FIX; then
  echo -e "${YELLOW}Auto-fixing settings on affected devices...${RESET}"
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    fix_device "${ip}:5555" &
    while (( $(jobs -r | wc -l) >= MAX_PARALLEL )); do sleep 0.2; done
  done <<< "$ALIVE"
  wait
  echo ""
fi

# Render output
case "$MODE" in
  table) render_table ;;
  csv)   render_csv ;;
  json)  render_json ;;
esac
