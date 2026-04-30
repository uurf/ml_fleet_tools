#!/usr/bin/env bash
# ============================================================
# Magic Leap 2 Fleet Deploy Tool — KAGAMI / Tin Drum
# Usage: ./ml_deploy.sh [command] [options]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.txt"
LOG_DIR="$SCRIPT_DIR/logs"
MAX_PARALLEL=20  # tune based on your network/router limits

mkdir -p "$LOG_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ---- Check for toolkit updates -------------------------------------
# Requires network — silently skips if offline.
# Hard stops if local repo is behind origin/main.
check_for_updates() {
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

usage() {
  echo ""
  echo -e "${BOLD}ML Fleet Deploy — KAGAMI${RESET}"
  echo -e "${DIM}  $TOOLKIT_VERSION${RESET}"
  echo ""
  echo "  Commands:"
  echo "    connect               Connect to all devices over WiFi ADB"
  echo "    status                Show online/offline status of all devices"
  echo "    install <path.apk>    Install APK to all online devices"
  echo "    push <src> <dest>     Push file/folder to all devices"
  echo "    launch <package>      Launch app on all devices"
  echo "    stop <package>        Stop app on all devices"
  echo "    restart <package>     Stop then launch app on all devices"
  echo "    reboot                Reboot all devices"
  echo "    shell <cmd>           Run any adb shell command on all devices"
  echo "    logs <package>        Stream logcat for a package from all devices"
  echo ""
  echo "  Options:"
  echo "    -d <ip>               Target a single device by IP"
  echo "    -f <file>             Use alternate devices file (default: devices.txt)"
  echo "    -j <n>                Max parallel jobs (default: $MAX_PARALLEL)"
  echo ""
  echo "  Examples:"
  echo "    ./ml_deploy.sh install builds/kagami_v2.apk"
  echo "    ./ml_deploy.sh push assets/ /sdcard/KAGAMI/"
  echo "    ./ml_deploy.sh restart com.tindrum.kagami"
  echo "    ./ml_deploy.sh shell 'pm list packages'"
  echo "    ./ml_deploy.sh -d 192.168.1.45 install builds/test.apk"
  echo ""
  exit 0
}

# ---- Device list ----
load_devices() {
  if [[ ! -f "$DEVICES_FILE" ]]; then
    echo -e "${RED}Error: devices.txt not found at $DEVICES_FILE${RESET}"
    echo "Create it with one IP per line, e.g.:"
    echo "  192.168.1.101"
    echo "  192.168.1.102"
    exit 1
  fi
  # Strip comments and blank lines
  grep -v '^\s*#' "$DEVICES_FILE" | grep -v '^\s*$' || true
}

# ---- Connect all devices via WiFi ADB ----
cmd_connect() {
  echo -e "${CYAN}Connecting to all devices...${RESET}"
  local devices
  devices=$(load_devices)
  local count=0 failed=0
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    if adb connect "${ip}:5555" 2>&1 | grep -q "connected"; then
      echo -e "  ${GREEN}✓${RESET} $ip"
      ((count++)) || true
    else
      echo -e "  ${RED}✗${RESET} $ip (failed)"
      ((failed++)) || true
    fi
  done <<< "$devices"
  echo ""
  echo -e "Connected: ${GREEN}$count${RESET}  Failed: ${RED}$failed${RESET}"
}

# ---- Get list of currently connected ADB devices ----
online_devices() {
  adb devices | grep -v "List of" | grep "device$" | awk '{print $1}' || true
}

# ---- Status check ----
cmd_status() {
  local all_devices online_list
  all_devices=$(load_devices)
  online_list=$(online_devices)
  local online=0 offline=0

  echo ""
  printf "%-22s %-10s %-30s\n" "IP" "STATUS" "OS VERSION"
  printf "%-22s %-10s %-30s\n" "──────────────────────" "──────────" "──────────────────────────────"

  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    local serial="${ip}:5555"
    if echo "$online_list" | grep -q "$serial"; then
      local osver
      osver=$(adb -s "$serial" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "unknown")
      printf "%-22s ${GREEN}%-10s${RESET} %-30s\n" "$ip" "online" "$osver"
      ((online++)) || true
    else
      printf "%-22s ${RED}%-10s${RESET}\n" "$ip" "offline"
      ((offline++)) || true
    fi
  done <<< "$all_devices"

  echo ""
  echo -e "Online: ${GREEN}$online${RESET}   Offline: ${RED}$offline${RESET}   Total: $((online + offline))"
  echo ""
}

# ---- Run a command in parallel across all online devices ----
run_parallel() {
  local cmd_fn="$1"; shift
  local devices
  devices=$(online_devices)

  if [[ -z "$devices" ]]; then
    echo -e "${RED}No devices online. Run: ./ml_deploy.sh connect${RESET}"
    exit 1
  fi

  local count
  count=$(echo "$devices" | wc -l | tr -d ' ')
  echo -e "${CYAN}Running on $count online device(s) [max $MAX_PARALLEL parallel]...${RESET}"
  echo ""

  local pids=() serials=()
  local running=0 success=0 fail=0
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  while IFS= read -r serial; do
    [[ -z "$serial" ]] && continue
    local logfile="$LOG_DIR/${timestamp}_${serial//:/_}.log"

    # Throttle parallelism
    while (( running >= MAX_PARALLEL )); do
      for i in "${!pids[@]}"; do
        if ! kill -0 "${pids[$i]}" 2>/dev/null; then
          wait "${pids[$i]}" && ((success++)) || ((fail++)) || true
          unset 'pids[$i]'
          unset 'serials[$i]'
          ((running--)) || true
        fi
      done
      sleep 0.1
    done

    "$cmd_fn" "$serial" "$@" > "$logfile" 2>&1 &
    pids+=($!)
    serials+=("$serial")
    ((running++)) || true

  done <<< "$devices"

  # Wait for remaining
  for i in "${!pids[@]}"; do
    local serial="${serials[$i]}"
    local logfile="$LOG_DIR/${timestamp}_${serial//:/_}.log"
    if wait "${pids[$i]}"; then
      echo -e "  ${GREEN}✓${RESET} $serial"
      ((success++)) || true
    else
      echo -e "  ${RED}✗${RESET} $serial — $(tail -1 "$logfile")"
      ((fail++)) || true
    fi
  done

  echo ""
  echo -e "Done — Success: ${GREEN}$success${RESET}  Failed: ${RED}$fail${RESET}"
  echo -e "Logs: $LOG_DIR/"
}

# ---- Per-device operations ----
do_install() { local s="$1" apk="$2"; adb -s "$s" install -r -g "$apk"; }
do_push()    { local s="$1" src="$2" dest="$3"; adb -s "$s" push "$src" "$dest"; }
do_launch()  { local s="$1" pkg="$2"; adb -s "$s" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1; }
do_stop()    { local s="$1" pkg="$2"; adb -s "$s" shell am force-stop "$pkg"; }
do_restart() {
  local s="$1" pkg="$2"
  adb -s "$s" shell am force-stop "$pkg"
  sleep 1
  adb -s "$s" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1
}
do_reboot()  { local s="$1"; adb -s "$s" reboot; }
do_shell()   { local s="$1"; shift; adb -s "$s" shell "$@"; }

# ---- Wrapper functions for export (needed for run_parallel subshell) ----
export -f do_install do_push do_launch do_stop do_restart do_reboot do_shell 2>/dev/null || true

# ---- Main ----
SINGLE_DEVICE=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) SINGLE_DEVICE="$2:5555"; shift 2 ;;
    -f) DEVICES_FILE="$2"; shift 2 ;;
    -j) MAX_PARALLEL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done

COMMAND="${1:-help}"
shift || true

# Override online_devices if single device mode
if [[ -n "$SINGLE_DEVICE" ]]; then
  online_devices() { echo "$SINGLE_DEVICE"; }
fi

case "$COMMAND" in
  connect)   cmd_connect ;;
  status)    cmd_status ;;
  install)
    [[ -z "${1:-}" ]] && { echo "Usage: install <path.apk>"; exit 1; }
    APK="$1"
    echo -e "${BOLD}Installing:${RESET} $APK"
    run_parallel do_install "$APK"
    ;;
  push)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Usage: push <src> <dest>"; exit 1; }
    echo -e "${BOLD}Pushing:${RESET} $1 → $2"
    run_parallel do_push "$1" "$2"
    ;;
  launch)
    [[ -z "${1:-}" ]] && { echo "Usage: launch <package>"; exit 1; }
    echo -e "${BOLD}Launching:${RESET} $1"
    run_parallel do_launch "$1"
    ;;
  stop)
    [[ -z "${1:-}" ]] && { echo "Usage: stop <package>"; exit 1; }
    echo -e "${BOLD}Stopping:${RESET} $1"
    run_parallel do_stop "$1"
    ;;
  restart)
    [[ -z "${1:-}" ]] && { echo "Usage: restart <package>"; exit 1; }
    echo -e "${BOLD}Restarting:${RESET} $1"
    run_parallel do_restart "$1"
    ;;
  reboot)
    echo -e "${YELLOW}Rebooting all devices...${RESET}"
    run_parallel do_reboot
    ;;
  shell)
    [[ -z "${1:-}" ]] && { echo "Usage: shell <command>"; exit 1; }
    echo -e "${BOLD}Running:${RESET} adb shell $*"
    run_parallel do_shell "$@"
    ;;
  logs)
    [[ -z "${1:-}" ]] && { echo "Usage: logs <package>"; exit 1; }
    PKG="$1"
    DEVICES=$(online_devices)
    echo -e "${CYAN}Streaming logcat for $PKG from all devices (Ctrl+C to stop)...${RESET}"
    echo "$DEVICES" | xargs -P0 -I{} adb -s {} logcat --pid="$(adb -s {} shell pidof "$PKG" 2>/dev/null)" -v time &
    wait
    ;;
  help|--help|-h) usage ;;
  *) echo -e "${RED}Unknown command: $COMMAND${RESET}"; usage ;;
esac
