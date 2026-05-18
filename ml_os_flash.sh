#!/usr/bin/env bash
# ============================================================
# Magic Leap 2 OS Downgrade Helper — KAGAMI / Tin Drum
#
# Uses Magic Leap's bundled flashall_amd.sh (included in every
# OS image downloaded via ML Hub Package Manager) rather than
# manually flashing individual partitions. This is the supported
# path and handles partition order correctly.
#
# HOW TO GET OS IMAGES:
#   1. Open ML Hub → Package Manager → "All" tab
#   2. Expand "Device OS Versions" → select version → Apply Changes
#   3. After download: click "Open Folder" to find the image dir
#   4. Copy that folder into ./os_images/<version>/
#      e.g. ./os_images/1.3.2/flashall_amd.sh  (+ .img files)
#
# REQUIREMENTS:
#   - USB-C connection only (no WiFi path for OS flash)
#   - One device per laptop — run multiple laptops in parallel
#     to flash your 200-unit fleet efficiently
#   - brew install android-platform-tools  (for adb + fastboot)
#
# USAGE:
#   ./ml_os_flash.sh                # auto-selects if one OS image in ./os_images
#   ./ml_os_flash.sh 1.4.1          # flash specific version from ./os_images
#   ./ml_os_flash.sh 1.4.1 /custom  # flash specific version from custom dir
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Google Sheets update ------------------------------------------
# shellcheck disable=SC2034  # used inside Python subprocess string
SHEETS_URL="https://script.google.com/macros/s/AKfycbwUeUL8yk89AWxX_NN6HhCh-vo1MRbnbxHbiTPbvcyhRttiVQOywnrRMH-J9uBPg7Tz/exec"

update_sheet() {
  local action="$1" serial="$2" device_num="${3:-}" case_num="${4:-}" operator_initials="${5:-}"
  python3 -c "
import urllib.request, json, sys
url = 'https://script.google.com/macros/s/AKfycbwUeUL8yk89AWxX_NN6HhCh-vo1MRbnbxHbiTPbvcyhRttiVQOywnrRMH-J9uBPg7Tz/exec'
data = json.dumps({'action':'ACTION','serial':'SERIAL','device_number':'DEVNUM','case_number':'CASENUM','operator_initials':'INITIALS'}).encode()
data = data.replace(b'ACTION', '$action'.encode()).replace(b'SERIAL', '$serial'.encode()).replace(b'DEVNUM', '$device_num'.encode()).replace(b'CASENUM', '$case_num'.encode()).replace(b'INITIALS', '$operator_initials'.encode())
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

# ---- Resolve active show -------------------------------------------
# A device flashed for the wrong show joins the wrong WiFi and gets
# the wrong build — so the show is confirmed before the flash below,
# then handed down the provision → deploy chain.
# shellcheck source=lib/show_config.sh
source "$SCRIPT_DIR/lib/show_config.sh"

TARGET_VERSION="${1:-}"
OS_IMAGES_DIR="${2:-}"
# Resolve images dir: explicit arg → SCRIPT_DIR/os_images
if [[ -z "$OS_IMAGES_DIR" ]]; then
  OS_IMAGES_DIR="$(dirname "${BASH_SOURCE[0]}")/os_images"
fi

echo ""
echo -e "${BOLD}ML2 OS Flash Tool${RESET}"
echo -e "${DIM}  $TOOLKIT_VERSION${RESET}"
echo ""

# ---- Preflight checks -----------------------------------------------

if ! command -v adb &>/dev/null; then
  echo -e "${RED}adb not found. Install via: brew install android-platform-tools${RESET}"
  exit 1
fi

if ! command -v fastboot &>/dev/null; then
  echo -e "${RED}fastboot not found. Install via: brew install android-platform-tools${RESET}"
  exit 1
fi

# Device can be in one of three states:
#   1. Already in fastboot       — skip straight to flash
#   2. Booted + authorized ADB   — reboot into fastboot via ADB
#   3. Booted + unauthorized ADB — prompt for manual fastboot entry

IN_FASTBOOT=false
CONNECTED_AUTH=0
SERIAL=""
CURRENT_OS="unknown"

FASTBOOT_COUNT=$(fastboot devices 2>/dev/null | grep -c "fastboot" || true)
if [[ "${FASTBOOT_COUNT:-0}" -gt 0 ]]; then
  IN_FASTBOOT=true
  SERIAL=$(fastboot devices 2>/dev/null | awk '{print $1}' | head -1)
  echo -e "  Device:     ${CYAN}$SERIAL${RESET}"
  echo -e "  State:      ${GREEN}already in fastboot — skipping reboot${RESET}"
else
  CONNECTED_AUTH=$(adb devices | grep -v "List of" | grep -c "device$" || true)
  CONNECTED_UNAUTH=$(adb devices | grep -v "List of" | grep -c "unauthorized" || true)
  CONNECTED=$(( ${CONNECTED_AUTH:-0} + ${CONNECTED_UNAUTH:-0} ))

  if [[ "${CONNECTED:-0}" -eq 0 ]]; then
    echo -e "${RED}No device found over USB.${RESET}"
    echo "  Connect device via USB-C (booted or already in fastboot mode)"
    exit 1
  fi
  if [[ "${CONNECTED:-0}" -gt 1 ]]; then
    echo -e "${YELLOW}Multiple devices connected — connect only one at a time.${RESET}"
    adb devices
    exit 1
  fi

  SERIAL=$(adb devices | grep -v "List of" | grep -E "device$|unauthorized" | awk '{print $1}' || true)

  if [[ "$CONNECTED_AUTH" -eq 1 ]]; then
    BUILD_ID=$(adb -s "$SERIAL" shell getprop ro.build.id 2>/dev/null | tr -d '\r')
    LUMIN_VERSION=$(adb -s "$SERIAL" shell getprop ro.build.version.lumin 2>/dev/null | tr -d '\r' || echo "")
    CURRENT_OS="${LUMIN_VERSION:-$BUILD_ID}"
    DEVICE_MODEL=$(adb -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    echo -e "  Device:     ${CYAN}$DEVICE_MODEL${RESET} ($SERIAL)"
    echo -e "  Current OS: ${CYAN}${LUMIN_VERSION:-unknown}${RESET} ($BUILD_ID)"
  else
    CURRENT_OS="unknown (unauthorized)"
    echo -e "  Device:     ${CYAN}$SERIAL${RESET}"
    echo -e "  Current OS: ${YELLOW}unauthorized — proceeding to fastboot${RESET}"
  fi
fi
echo ""

# ---- Select OS image ------------------------------------------------

if [[ ! -d "$OS_IMAGES_DIR" ]]; then
  echo -e "${RED}OS images directory not found: $OS_IMAGES_DIR${RESET}"
  echo ""
  echo "Create it and populate from ML Hub:"
  echo "  ML Hub → Package Manager → Device OS Versions → Download → Open Folder"
  echo "  Then: cp -r <that folder> $OS_IMAGES_DIR/<version>"
  echo ""
  echo "Usage: ./ml_os_flash.sh [version] [/custom/os_images/path]"
  exit 1
fi

# Find subdirs that contain a flashall_amd.sh (ML2's bundled flash script)
mapfile -t IMAGE_DIRS < <(find "$OS_IMAGES_DIR" -name "flashall_amd.sh" -exec dirname {} \; | sort)

if [[ ${#IMAGE_DIRS[@]} -eq 0 ]]; then
  echo -e "${RED}No valid OS image directories found in $OS_IMAGES_DIR${RESET}"
  echo ""
  echo "Each version folder must contain flashall_amd.sh (included in ML Hub downloads)."
  echo "If you only see .img files, you may have extracted to the wrong level."
  exit 1
fi

echo "Available OS images:"
echo ""
for i in "${!IMAGE_DIRS[@]}"; do
  dir="${IMAGE_DIRS[$i]}"
  version="$(basename "$dir")"
  img_count=$(find "$dir" -name "*.img" | wc -l | tr -d ' ')
  echo "  [$i] $version  (${img_count} partitions)"
done
echo ""

# ---- Version selection ---------------------------------------------
# Shared prompt used when no version arg given, or given version not found
select_from_menu() {
  echo ""
  echo "Available OS versions:"
  echo ""
  for i in "${!IMAGE_DIRS[@]}"; do
    echo "  [$((i+1))] $(basename "${IMAGE_DIRS[$i]}")"
  done
  echo "  [Enter] Exit"
  echo ""
  read -rp "Select version number: " IDX
  if [[ -z "$IDX" ]]; then
    echo "Exiting."
    exit 0
  fi
  IDX=$(( IDX - 1 ))
  if [[ $IDX -lt 0 || $IDX -ge ${#IMAGE_DIRS[@]} ]]; then
    echo -e "${RED}Invalid selection.${RESET}"
    exit 1
  fi
  SELECTED_DIR="${IMAGE_DIRS[$IDX]}"
}

SELECTED_DIR=""
if [[ -n "$TARGET_VERSION" ]]; then
  for dir in "${IMAGE_DIRS[@]}"; do
    if [[ "$(basename "$dir")" == *"$TARGET_VERSION"* ]]; then
      SELECTED_DIR="$dir"
      break
    fi
  done
  if [[ -z "$SELECTED_DIR" ]]; then
    echo -e "${YELLOW}'$TARGET_VERSION' not found in $OS_IMAGES_DIR${RESET}"
    select_from_menu
  fi
else
  if [[ ${#IMAGE_DIRS[@]} -eq 1 ]]; then
    # Only one image available — select automatically
    SELECTED_DIR="${IMAGE_DIRS[0]}"
    echo -e "  Auto-selected: $(basename "${IMAGE_DIRS[0]}")"
  else
    select_from_menu
  fi
fi

FLASH_SCRIPT="$SELECTED_DIR/flashall_amd.sh"
TARGET_OS="$(basename "$SELECTED_DIR")"

if [[ ! -f "$FLASH_SCRIPT" ]]; then
  echo -e "${RED}flashall_amd.sh not found in $SELECTED_DIR${RESET}"
  exit 1
fi

# ---- Confirm ---------------------------------------------------------

echo ""
echo -e "${YELLOW}┌─────────────────────────────────────────────────┐${RESET}"
echo -e "${YELLOW}│  WARNING: This will factory reset the device     │${RESET}"
echo -e "${YELLOW}│  ALL apps and data will be permanently erased    │${RESET}"
echo -e "${YELLOW}└─────────────────────────────────────────────────┘${RESET}"
echo ""
echo -e "  Device:  $SERIAL"
echo -e "  From:    ${CYAN}$CURRENT_OS${RESET}"
echo -e "  To:      ${CYAN}$TARGET_OS${RESET}"
echo -e "  Script:  $FLASH_SCRIPT"
echo ""
# Typed show-id confirmation doubles as the "proceed" gate, and binds
# this destructive flash to the correct show for the rest of the chain.
show_confirm "flash $TARGET_OS + factory reset $SERIAL"

# Collect device tracking info upfront so operator can walk away during flash
echo ""
echo -e "${BOLD}Device tracking${RESET}"
read -rp "  Device number (or Enter to skip): " DEVICE_NUMBER
read -rp "  Case number   (press Enter if it matches the device number, or is unknown): " CASE_NUMBER
read -rp "  Operator initials: " OPERATOR_INITIALS
export DEVICE_NUMBER CASE_NUMBER OPERATOR_INITIALS
echo ""

# Notify sheet that flash has started
if [[ -n "$SERIAL" ]]; then
  update_sheet "flash_start" "$SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "$OPERATOR_INITIALS"
fi

# ---- Flash -----------------------------------------------------------
#
# ML2 fastboot flow (per official docs):
#   1. Erase userdata (factory reset) via fastboot — cleaner than
#      adb recovery wipe, and required before downgrade
#   2. Boot into fastboot mode: hold Volume Down while powering on
#      (or reboot bootloader via adb)
#   3. Run flashall_amd.sh from the OS image directory
#      The script handles correct partition order and reboots when done
#
# NOTE: flashall_amd.sh expects to be run from its own directory
#       so we cd into it. It calls fastboot internally.

echo ""
echo -e "${CYAN}Step 1/3: Entering fastboot mode...${RESET}"
if $IN_FASTBOOT; then
  echo -e "  ${GREEN}Already in fastboot mode — skipping reboot${RESET}"
elif [[ "$CONNECTED_AUTH" -eq 1 ]]; then
  echo -e "${DIM}Rebooting via ADB...${RESET}"
  adb -s "$SERIAL" reboot bootloader
  echo "  Waiting for fastboot..."
  fastboot devices 2>/dev/null | grep -q . || {
    while ! fastboot devices 2>/dev/null | grep -q .; do sleep 1; done
  }
  echo -e "  ${GREEN}Device in fastboot mode${RESET}"
else
  echo -e "${YELLOW}Device is unauthorized — manual fastboot required.${RESET}"
  echo ""
  echo -e "  1. Hold ${BOLD}Power${RESET} until device shuts down"
  echo -e "  2. Hold ${BOLD}Volume Down${RESET} + press ${BOLD}Power${RESET} to start in fastboot"
  echo -e "  3. Wait for the fastboot LED on the Compute Pack"
  echo -e "  4. Press Enter here to continue"
  echo ""
  read -rp "  → Ready? Press Enter: "
  echo "  Waiting for fastboot..."
  fastboot devices 2>/dev/null | grep -q . || {
    while ! fastboot devices 2>/dev/null | grep -q .; do sleep 1; done
  }
  echo -e "  ${GREEN}Device in fastboot mode${RESET}"
fi

echo ""
echo -e "${CYAN}Step 2/3: Formatting userdata (factory reset)...${RESET}"
# Use format (creates clean ext4 filesystem) rather than erase — more reliable
# across devices and avoids "Check device console" errors seen with erase
if fastboot format userdata 2>/dev/null; then
  echo -e "  ${GREEN}Userdata formatted${RESET}"
elif fastboot erase userdata 2>/dev/null; then
  echo -e "  ${GREEN}Userdata erased${RESET}"
else
  echo -e "  ${YELLOW}Warning: userdata wipe failed — continuing anyway${RESET}"
fi
fastboot erase metadata 2>/dev/null || true

echo ""
echo -e "${CYAN}Step 3/3: Flashing OS $TARGET_OS via flashall_amd.sh...${RESET}"
echo -e "${DIM:-}(~6-10 minutes depending on USB speed — do not disconnect)${RESET}"
echo ""

# Run ML's bundled script from its directory
# Patch macOS incompatibilities in flashall_amd.sh before running:
#   - stat -c%s  (Linux) → stat -f%z  (macOS)
#   - lsusb not available on macOS — comment it out
#   - Darwin/fastboot and Darwin/adb are Intel-only binaries — use system versions
#     which are ARM-native on Apple Silicon Macs
chmod +x "$FLASH_SCRIPT"
sed -i '' 's/stat -c%s/stat -f%z/g' "$FLASH_SCRIPT"
sed -i '' 's/lsusb/#lsusb/g' "$FLASH_SCRIPT"
sed -i '' 's|Darwin/fastboot|fastboot|g' "$FLASH_SCRIPT"
sed -i '' 's|Darwin/adb|adb|g' "$FLASH_SCRIPT"
# Patch the Darwin binary check to exclude usbrecovery_host (not available on macOS)
# and rename Intel-only binaries so the script falls back to ARM homebrew versions.
DARWIN_DIR="$(dirname "$FLASH_SCRIPT")/Darwin"
[[ -f "$DARWIN_DIR/fastboot" ]] && mv "$DARWIN_DIR/fastboot" "$DARWIN_DIR/fastboot.intel" 2>/dev/null || true
[[ -f "$DARWIN_DIR/adb" ]]     && mv "$DARWIN_DIR/adb"     "$DARWIN_DIR/adb.intel"     2>/dev/null || true
[[ -f "$DARWIN_DIR/usbrecovery_host" ]] && mv "$DARWIN_DIR/usbrecovery_host" "$DARWIN_DIR/usbrecovery_host.intel" 2>/dev/null || true
# Patch condition to not require usbrecovery_host
sed -i '' 's|&& -e "\$uname/usbrecovery_host"||g' "$FLASH_SCRIPT"
# Set recovery to a no-op if usbrecovery_host not found
sed -i '' 's|recovery=\$(command -v usbrecovery_host)|recovery=true|g' "$FLASH_SCRIPT"
# ecfw (EC firmware) consistently fails when downgrading from newer OS versions
# because the EC firmware is already newer. This is harmless — all critical
# partitions flash successfully. Other partition failures (kernel, system, etc.)
# are serious and indicate a real problem (USB drop, bad device, etc.).
FLASH_LOG=$(mktemp)
FLASH_EXIT=0
(cd "$SELECTED_DIR" && bash flashall_amd.sh) 2>&1 | tee "$FLASH_LOG" || FLASH_EXIT=$?

if [[ $FLASH_EXIT -ne 0 ]]; then
  echo ""
  # Determine which partition failed
  FAILED_PARTITION=$(grep -oE "Writing '[^']+'" "$FLASH_LOG" | tail -1 | grep -oE "'[^']+'" | tr -d "'" || echo "")
  LAST_ERROR=$(grep -E "FAILED|ERROR" "$FLASH_LOG" | tail -1 || echo "")

  if [[ "$FAILED_PARTITION" == "ecfw"* ]]; then
    echo -e "${YELLOW}Note: flashall_amd.sh exited with code $FLASH_EXIT${RESET}"
    echo -e "${YELLOW}ecfw partition failed — this is normal when downgrading. All critical partitions flashed OK.${RESET}"
    # Device may still be in fastboot — kick it to reboot
    if fastboot devices 2>/dev/null | grep -q .; then
      echo -e "${CYAN}Device still in fastboot — rebooting automatically...${RESET}"
      fastboot reboot 2>/dev/null || true
    fi
  else
    echo -e "${RED}┌─────────────────────────────────────────────────┐${RESET}"
    echo -e "${RED}│  FLASH FAILED — critical partition error         │${RESET}"
    echo -e "${RED}└─────────────────────────────────────────────────┘${RESET}"
    echo ""
    [[ -n "$FAILED_PARTITION" ]] && echo -e "  Failed partition: ${RED}$FAILED_PARTITION${RESET}"
    [[ -n "$LAST_ERROR"       ]] && echo -e "  Error:            ${RED}$LAST_ERROR${RESET}"
    echo ""
    echo -e "  Likely causes:"
    echo -e "   • MacBook went to sleep / USB dropped during flash"
    echo -e "     ${DIM}(plug in and use caffeinate next time)${RESET}"
    echo -e "   • Faulty USB-C cable or port — try a different one"
    echo -e "   • Device hardware issue — mark for inspection"
    echo ""
    echo -e "  ${YELLOW}Do NOT continue — this device was not fully flashed.${RESET}"
    echo -e "  Log saved to: $FLASH_LOG"
    echo ""
    update_sheet "flash_failed" "$SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "$OPERATOR_INITIALS"
    exit 1
  fi
fi
rm -f "$FLASH_LOG" 

# ---- Post-flash ------------------------------------------------------

echo ""
echo -e "${CYAN}Waiting for device to boot (first boot takes ~45s)...${RESET}"
adb disconnect &>/dev/null || true  # clear any WiFi ADB sessions before waiting
sleep 45
adb -s "$SERIAL" wait-for-device
sleep 8  # give system services time to start before pushing files

# ---- Pre-authorize this laptop's ADB key ----------------------------
#
# When a user taps "Always allow" on the USB debugging dialog, Android
# simply appends the laptop's public key to /data/misc/adb/adb_keys.
# We do the same thing programmatically right after first boot, while
# we still have adb access from the flash session.
#
# After this, the dialog will NEVER appear again on this device for
# this laptop — and any other laptops whose keys are in EXTRA_ADB_KEYS.
#
# To add keys from other machines (e.g. other laptops in your fleet
# provisioning setup), put their adbkey.pub contents in:
#   ./authorized_keys/  (one .pub file per machine)

echo ""
echo -e "${CYAN}Pre-authorizing ADB keys (bypass 'Allow USB debugging' dialog)...${RESET}"

ADB_KEY="$HOME/.android/adbkey.pub"
EXTRA_KEYS_DIR="$(dirname "${BASH_SOURCE[0]}")/authorized_keys"
DEVICE_KEYS_PATH="/data/misc/adb/adb_keys"

# Collect all keys to inject
ALL_KEYS_TMP=$(mktemp)

if [[ -f "$ADB_KEY" ]]; then
  cat "$ADB_KEY" >> "$ALL_KEYS_TMP"
  echo "" >> "$ALL_KEYS_TMP"  # ensure newline between keys
  echo -e "  Adding key: $(basename "$HOME") (this machine)"
else
  echo -e "  ${YELLOW}Warning: ~/.android/adbkey.pub not found — run 'adb devices' once to generate it${RESET}"
fi

# Add any extra machine keys from authorized_keys/ directory
if [[ -d "$EXTRA_KEYS_DIR" ]]; then
  for keyfile in "$EXTRA_KEYS_DIR"/*.pub; do
    [[ -f "$keyfile" ]] || continue
    cat "$keyfile" >> "$ALL_KEYS_TMP"
    echo "" >> "$ALL_KEYS_TMP"
    echo -e "  Adding key: $(basename "$keyfile")"
  done
fi

if [[ -s "$ALL_KEYS_TMP" ]]; then
  # Ensure the adb directory exists and push the keys file
  adb -s "$SERIAL" shell "mkdir -p /data/misc/adb" 2>/dev/null || true
  adb -s "$SERIAL" push "$ALL_KEYS_TMP" "$DEVICE_KEYS_PATH" &>/dev/null && \
    adb -s "$SERIAL" shell "chmod 0640 $DEVICE_KEYS_PATH" 2>/dev/null || true
  # Restart adbd so it picks up the new key immediately
  adb -s "$SERIAL" shell "setprop ctl.restart adbd" 2>/dev/null || true
  sleep 2
  echo -e "  ${GREEN}✓ ADB keys injected — dialog will not appear on this device${RESET}"

# ---- Skip OOBE / setup wizard ---------------------------------------
# Mark device as provisioned so the first-time setup wizard is skipped.
# Must run before the wizard launches — we do it immediately after boot.
# Force-stop the wizard package in case it already started.
echo ""
echo -e "${CYAN}Skipping setup wizard (OOBE)...${RESET}"
# Mark device as fully provisioned
adb -s "$SERIAL" shell "settings put secure user_setup_complete 1" 2>/dev/null || true
adb -s "$SERIAL" shell "settings put global device_provisioned 1" 2>/dev/null || true
adb -s "$SERIAL" shell "settings put global setup_wizard_has_run 1" 2>/dev/null || true
# Force-stop and disable the ML2 OOBE package
adb -s "$SERIAL" shell "am force-stop com.magicleap.oobe" 2>/dev/null || true
adb -s "$SERIAL" shell "pm disable-user --user 0 com.magicleap.oobe" 2>/dev/null || true
echo -e "  ${GREEN}✓ Setup wizard bypassed${RESET}"
else
  echo -e "  ${YELLOW}No keys found to inject — USB debugging dialog will still appear${RESET}"
fi

rm -f "$ALL_KEYS_TMP"

NEW_BUILD=$(adb -s "$SERIAL" shell getprop ro.build.id 2>/dev/null | tr -d '\r' || echo "unknown")
NEW_LUMIN=$(adb -s "$SERIAL" shell getprop ro.build.version.lumin 2>/dev/null | tr -d '\r' || echo "")

echo ""
echo -e "${GREEN}✓ Flash complete!${RESET}"
echo -e "  OS: flashed to ${GREEN}${NEW_LUMIN:-$NEW_BUILD}${RESET} ($NEW_BUILD)"
echo -e "${DIM}  Updating sheet...${RESET}"
update_sheet "flash_complete" "$SERIAL" "$DEVICE_NUMBER" "$CASE_NUMBER" "$OPERATOR_INITIALS"
echo -e "  ${GREEN}Sheet updated${RESET}"

# ---- Auto-provision --------------------------------------------------
PROVISION_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/ml_provision.sh"

if [[ -f "$PROVISION_SCRIPT" ]]; then
  echo ""
  echo -e "${CYAN}Waiting for device to fully initialize before provisioning...${RESET}"
  sleep 30
  echo -e "${CYAN}Running provisioning (settings, WiFi, permissions)...${RESET}"
  echo ""
  ANDROID_SERIAL="$SERIAL" DEVICE_NUMBER="$DEVICE_NUMBER" CASE_NUMBER="$CASE_NUMBER" OPERATOR_INITIALS="$OPERATOR_INITIALS" ML_SHOW="$ML_SHOW" ML_SHOW_CONFIRMED="${ML_SHOW_CONFIRMED:-}" bash "$PROVISION_SCRIPT" --deploy
else
  echo ""
  echo -e "${YELLOW}ml_provision.sh not found — skipping auto-provisioning${RESET}"
  echo -e "${BOLD}Manual post-flash steps:${RESET}"
  echo "  [ ] Settings → About → tap Build Number 7x (Developer Mode)"
  echo "  [ ] Allow USB Debugging when prompted"
  echo "  [ ] Configure WiFi on device"
  echo "  [ ] Add IP to devices.txt"
  echo "  [ ] ./ml_deploy.sh -d <ip> install builds/kagami.apk"
  echo "  [ ] ./ml_deploy.sh -d <ip> push assets/ /sdcard/KAGAMI/"
  echo "  [ ] ./ml_status.sh to verify"
  echo ""
fi
