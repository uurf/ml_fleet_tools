#!/usr/bin/env bash
# ============================================================
# ml_ssd_copy.sh — Copy SSD show data → device
#
# Finds USB-C attached SSD on device, discovers [showName]_data
# directories, prompts operator to select a show, then copies
# contents to /sdcard/[showName]/data on all target devices.
#
# Usage:
#   ./ml_ssd_copy.sh                  # all devices in devices.txt
#   ./ml_ssd_copy.sh -d <ip>          # single device by IP
#   ./ml_ssd_copy.sh -f <file>        # alternate devices file
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/../devices.txt"
MAX_PARALLEL=8

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"; CROSS="${RED}✗${RESET}"

# ── Arg parsing ────────────────────────────────────────────
SINGLE_DEVICE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) SINGLE_DEVICE="$2:5555"; shift 2 ;;
    -f) DEVICES_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ./ml_ssd_copy.sh [-d <ip>] [-f <devices_file>]"
      exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${RESET}"; exit 1 ;;
  esac
done

# ── Device list ────────────────────────────────────────────
load_devices() {
  if [[ -n "$SINGLE_DEVICE" ]]; then
    echo "$SINGLE_DEVICE"
    return
  fi
  if [[ ! -f "$DEVICES_FILE" ]]; then
    echo -e "${RED}Error: devices.txt not found at $DEVICES_FILE${RESET}"
    exit 1
  fi
  grep -v '^\s*#' "$DEVICES_FILE" | grep -v '^\s*$' | sed 's/$/:5555/' || true
}

online_devices() {
  adb devices | grep -v "List of" | grep "device$" | awk '{print $1}' || true
}

# ── Connect ────────────────────────────────────────────────
connect_devices() {
  echo -e "${CYAN}Connecting to devices...${RESET}"
  local connected=0 failed=0
  while IFS= read -r serial; do
    [[ -z "$serial" ]] && continue
    local ip="${serial%%:*}"
    if adb connect "${ip}:5555" 2>&1 | grep -q "connected"; then
      echo -e "  ${TICK} $ip"
      connected=$(( connected + 1 ))
    else
      echo -e "  ${CROSS} $ip (failed to connect)"
      failed=$(( failed + 1 ))
    fi
  done <<< "$(load_devices)"
  echo ""
  [[ $connected -eq 0 ]] && echo -e "${RED}No devices connected.${RESET}" && exit 1
}

# ── Find USB-C SSD mount on device ────────────────────────
# Returns mount path if it contains at least one *_data directory
find_ssd_mount() {
  local serial="$1"
  adb -s "$serial" shell "
    for path in /mnt/media_rw/* /storage/*; do
      [ -d \"\$path\" ] || continue
      name=\$(basename \"\$path\")
      case \"\$name\" in emulated|self|0|sdcard) continue ;; esac
      found=\$(ls -d \"\$path\"/*_data 2>/dev/null | head -1)
      [ -n \"\$found\" ] && echo \"\$path\" && break
    done
  " </dev/null 2>/dev/null | tr -d '\r' | head -1
}

# ── List *_data dirs on the SSD ───────────────────────────
list_show_dirs() {
  local serial="$1" ssd_mount="$2"
  adb -s "$serial" shell "
    for d in '$ssd_mount'/*_data; do
      [ -d \"\$d\" ] && basename \"\$d\"
    done
  " </dev/null 2>/dev/null | tr -d '\r'
}

# ── Copy for a single device ───────────────────────────────
copy_device() {
  local serial="$1" show_name="$2" src="$3" dest="$4"
  local ip="${serial%%:*}"
  local prefix="  [${CYAN}${ip}${RESET}]"

  echo -e "${prefix} Source:         ${DIM}${src}${RESET}"
  echo -e "${prefix} Destination:    ${DIM}${dest}${RESET}"

  # Write file list to temp file to prevent adb calls consuming stdin
  local tmp_list
  tmp_list=$(mktemp)
  adb -s "$serial" shell "find '$src' -type f 2>/dev/null" </dev/null | tr -d '\r' > "$tmp_list"

  local total
  total=$(wc -l < "$tmp_list" | tr -d ' ')
  echo -e "${prefix} Files to copy:  ${total}"

  # Ensure destination exists
  adb -s "$serial" shell "mkdir -p '$dest'" </dev/null 2>/dev/null

  local copied=0 skipped=0 errors=0

  while IFS= read -r src_file; do
    [[ -z "$src_file" ]] && continue

    # Skip .DS_Store
    local fname
    fname=$(basename "$src_file")
    if [[ "$fname" == ".DS_Store" ]]; then
      skipped=$(( skipped + 1 ))
      continue
    fi

    # Compute relative path and destination
    local rel_path="${src_file#${src}/}"
    local dest_file="${dest}/${rel_path}"
    local dest_dir
    dest_dir=$(dirname "$dest_file")

    # Ensure destination subdirectory exists
    adb -s "$serial" shell "mkdir -p '$dest_dir'" </dev/null 2>/dev/null

    # Copy the file
    if adb -s "$serial" shell "cp '$src_file' '$dest_file'" </dev/null 2>/dev/null; then
      copied=$(( copied + 1 ))
    else
      echo -e "${prefix} ${CROSS} Failed: ${DIM}${rel_path}${RESET}"
      errors=$(( errors + 1 ))
    fi

    # Progress every 10 files and on last file
    local done_count=$(( copied + skipped + errors ))
    if (( done_count % 10 == 0 )) || (( done_count == total )); then
      local pct=$(( total > 0 ? done_count * 100 / total : 100 ))
      printf "\r${prefix} Progress: ${GREEN}%d${RESET}/%d  (%d%%)   " \
        "$done_count" "$total" "$pct"
    fi

  done < "$tmp_list"
  rm -f "$tmp_list"

  echo ""
  echo -e "${prefix} ${TICK} Done — ${GREEN}${copied}${RESET} copied, ${skipped} skipped, ${RED}${errors}${RESET} errors"
  [[ $errors -gt 0 ]] && return 1 || return 0
}

# ── Main ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   ML SSD Copy — Tin Drum                     ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""

connect_devices

ONLINE=$(online_devices) || true
if [[ -z "$ONLINE" ]]; then
  echo -e "${RED}No devices online after connect.${RESET}"
  exit 1
fi

# Filter to only devices we targeted
TARGETS=$(load_devices) || true
DEVICES_TO_RUN=()
while IFS= read -r serial; do
  [[ -z "$serial" ]] && continue
  if echo "$ONLINE" | grep -q "$serial"; then
    DEVICES_TO_RUN+=("$serial")
  else
    echo -e "  ${CROSS} ${serial%%:*} — not reachable, skipping"
  fi
done <<< "$TARGETS"

if [[ ${#DEVICES_TO_RUN[@]} -eq 0 ]]; then
  echo -e "${RED}No target devices are online.${RESET}"
  exit 1
fi

# ── Discover SSD and show dirs (probe first online device) ─
PROBE_DEVICE="${DEVICES_TO_RUN[0]}"
PROBE_IP="${PROBE_DEVICE%%:*}"

echo -e "${CYAN}Probing SSD on ${PROBE_IP}...${RESET}"
SSD_MOUNT=$(find_ssd_mount "$PROBE_DEVICE")

if [[ -z "$SSD_MOUNT" ]]; then
  echo -e "${RED}No USB-C SSD with *_data directories found on ${PROBE_IP}.${RESET}"
  echo -e "${DIM}Make sure the SSD is connected to the device via USB-C.${RESET}"
  exit 1
fi

echo -e "  ${TICK} SSD mounted at: ${DIM}${SSD_MOUNT}${RESET}"
echo ""

# Get list of *_data dirs
mapfile -t SHOW_DIRS < <(list_show_dirs "$PROBE_DEVICE" "$SSD_MOUNT")

if [[ ${#SHOW_DIRS[@]} -eq 0 ]]; then
  echo -e "${RED}No *_data directories found on SSD at ${SSD_MOUNT}.${RESET}"
  exit 1
fi

# ── Show selection ─────────────────────────────────────────
SELECTED_DIR=""
SHOW_NAME=""

if [[ ${#SHOW_DIRS[@]} -eq 1 ]]; then
  SELECTED_DIR="${SHOW_DIRS[0]}"
  SHOW_NAME="${SELECTED_DIR%_data}"
  echo -e "  Found: ${BOLD}${SHOW_NAME}${RESET}"
  echo ""
  read -r -p "  Proceed with ${SHOW_NAME}? [Y/n] " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
else
  echo -e "${BOLD}Shows found on SSD:${RESET}"
  echo ""
  for i in "${!SHOW_DIRS[@]}"; do
    echo -e "  [$(( i + 1 ))] ${SHOW_DIRS[$i]%_data}"
  done
  echo ""
  while true; do
    read -r -p "  Select show [1-${#SHOW_DIRS[@]}]: " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && \
       (( selection >= 1 )) && (( selection <= ${#SHOW_DIRS[@]} )); then
      SELECTED_DIR="${SHOW_DIRS[$((selection - 1))]}"
      SHOW_NAME="${SELECTED_DIR%_data}"
      break
    fi
    echo -e "  ${YELLOW}Please enter a number between 1 and ${#SHOW_DIRS[@]}${RESET}"
  done
fi

echo ""

SRC="${SSD_MOUNT}/${SELECTED_DIR}"
DEST="/sdcard/${SHOW_NAME}/data"

echo -e "${CYAN}Copying to ${#DEVICES_TO_RUN[@]} device(s)...${RESET}"
echo -e "  Show:  ${BOLD}${SHOW_NAME}${RESET}"
echo -e "  From:  ${DIM}${SRC}${RESET}"
echo -e "  To:    ${DIM}${DEST}${RESET}"
echo ""

# ── Parallel copy ──────────────────────────────────────────
success=0; fail=0
pids=()

for serial in "${DEVICES_TO_RUN[@]}"; do
  while (( ${#pids[@]} >= MAX_PARALLEL )); do
    pids=($(for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && echo "$p"; done))
    sleep 0.2
  done

  ( copy_device "$serial" "$SHOW_NAME" "$SRC" "$DEST" ) &
  pids+=($!)
done

for p in "${pids[@]}"; do
  if wait "$p"; then
    success=$(( success + 1 ))
  else
    fail=$(( fail + 1 ))
  fi
done

echo ""
echo -e "────────────────────────────────────────────────"
echo -e "Result — ${GREEN}${success}${RESET} succeeded  ${RED}${fail}${RESET} failed"
echo ""
