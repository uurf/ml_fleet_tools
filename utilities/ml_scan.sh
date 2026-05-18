#!/usr/bin/env bash
# ============================================================
# ml_scan.sh — Scan network for ML2 devices → devices.txt
#
# Discovers Magic Leap 2 headsets on the local network by
# scanning for ADB port 5555. Works with both DHCP and static
# addressing. Prints discovered IPs, lets you confirm, then
# writes (or appends) to devices.txt.
#
# Usage:
#   ./ml_scan.sh                        # scan, prompt, write devices.txt
#   ./ml_scan.sh --subnet 10.0.1.0/24  # override subnet
#   ./ml_scan.sh --append               # append to existing devices.txt
#   ./ml_scan.sh --yes                  # skip confirmation, write all found
#   ./ml_scan.sh --dry-run              # print results, don't write anything
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/show_config.sh
source "$SCRIPT_DIR/../lib/show_config.sh"
# Scan writes the canonical per-show fleet list (not the legacy fallback)
DEVICES_FILE="$SHOW_DEVICES_FILE_DEFAULT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"; CROSS="${RED}✗${RESET}"

ADB_PORT=5555
TIMEOUT=1          # per-host ping/nc timeout (seconds)
MAX_PARALLEL=64    # parallel scan jobs

# ── Defaults ────────────────────────────────────────────────
SUBNET=""          # auto-detect if blank
APPEND=false
AUTO_YES=false
DRY_RUN=false

# ── Arg parsing ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subnet)   SUBNET="$2"; shift 2 ;;
    --append)   APPEND=true; shift ;;
    --yes|-y)   AUTO_YES=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -f)         DEVICES_FILE="$2"; shift 2 ;;
    -h|--help)
      echo ""
      echo -e "${BOLD}ml_scan.sh${RESET} — Discover ML2 devices on the network"
      echo ""
      echo "  Options:"
      echo "    --subnet <cidr>   Subnet to scan (default: auto-detect)"
      echo "    --append          Append found IPs to existing devices.txt"
      echo "    --yes, -y         Skip confirmation prompt"
      echo "    --dry-run         Print results only, don't write devices.txt"
      echo "    -f <file>         Use alternate output file"
      echo ""
      echo "  Examples:"
      echo "    ./ml_scan.sh"
      echo "    ./ml_scan.sh --subnet 192.168.10.0/24"
      echo "    ./ml_scan.sh --append --yes"
      echo ""
      exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${RESET}"; exit 1 ;;
  esac
done

# ── Detect subnet ────────────────────────────────────────────
detect_subnet() {
  local iface ip prefix

  # macOS
  if command -v ipconfig &>/dev/null && [[ "$(uname)" == "Darwin" ]]; then
    iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -1)
    if [[ -n "$iface" ]]; then
      ip=$(ipconfig getifaddr "$iface" 2>/dev/null || echo "")
      if [[ -n "$ip" ]]; then
        # Get prefix length via ifconfig
        prefix=$(ifconfig "$iface" 2>/dev/null | awk '/netmask/{print $4}' | head -1)
        # Convert hex netmask to CIDR
        if [[ "$prefix" =~ ^0x ]]; then
          local mask=$((16#${prefix#0x}))
          local cidr=0
          while (( mask > 0 )); do (( cidr += mask & 1 )); (( mask >>= 1 )); done
          # Round to common values
          [[ $cidr -ge 24 ]] && cidr=24
          [[ $cidr -ge 16 && $cidr -lt 24 ]] && cidr=24
          echo "${ip%.*}.0/${cidr}"
          return
        fi
        echo "${ip%.*}.0/24"
        return
      fi
    fi
  fi

  # Linux
  if command -v ip &>/dev/null; then
    local subnet
    subnet=$(ip -o -f inet addr show 2>/dev/null \
      | awk '$2 !~ /^lo/ {print $4}' \
      | head -1)
    if [[ -n "$subnet" ]]; then
      # Convert to network address
      local addr prefix_len
      addr="${subnet%/*}"
      prefix_len="${subnet#*/}"
      local IFS='.'; read -r a b c _ <<< "$addr"; unset IFS
      echo "${a}.${b}.${c}.0/${prefix_len}"
      return
    fi
  fi

  # Fallback
  echo "192.168.1.0/24"
}

# ── Generate host list from CIDR ─────────────────────────────
cidr_hosts() {
  local cidr="$1"
  local net="${cidr%/*}"
  local prefix="${cidr#*/}"
  local IFS='.'; read -r a b c d_net <<< "$net"; unset IFS
  local base=$(( (a<<24) | (b<<16) | (c<<8) | d_net ))
  local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
  local network=$(( base & mask ))
  local broadcast=$(( network | (~mask & 0xFFFFFFFF) ))
  local count=$(( broadcast - network - 1 ))

  if (( count > 1024 )); then
    echo -e "${YELLOW}⚠  Subnet ${cidr} has $count hosts — this may take a while.${RESET}" >&2
    echo -e "   Use ${CYAN}--subnet <smaller_cidr>${RESET} to narrow the scan." >&2
    echo "" >&2
  fi

  for (( i = network + 1; i < broadcast; i++ )); do
    printf "%d.%d.%d.%d\n" \
      "$(( (i >> 24) & 0xFF ))" \
      "$(( (i >> 16) & 0xFF ))" \
      "$(( (i >>  8) & 0xFF ))" \
      "$(( i & 0xFF ))"
  done
}

# ── Probe a single host for ADB port ─────────────────────────
# Writes IP to $SCAN_TMP/found/ if port is open
probe_host() {
  local ip="$1"
  local found_dir="$2"

  # Quick ping first to avoid hanging nc on non-existent hosts
  if ping -c 1 -W "$TIMEOUT" -t "$TIMEOUT" "$ip" &>/dev/null 2>&1 || \
     ping -c 1 -W "$TIMEOUT" "$ip" &>/dev/null 2>&1; then
    # Host alive — check ADB port
    if nc -z -w "$TIMEOUT" "$ip" "$ADB_PORT" &>/dev/null 2>&1; then
      echo "$ip" > "${found_dir}/${ip}"
    fi
  fi
}

export -f probe_host
export ADB_PORT TIMEOUT

# ── Try to identify a device via ADB ─────────────────────────
adb_identify() {
  local ip="$1"
  local serial="${ip}:${ADB_PORT}"
  local model hw_serial os_ver

  # Try connecting (non-fatal)
  adb connect "$serial" &>/dev/null || true
  sleep 0.4

  if adb devices | grep -q "$serial"; then
    model=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "")
    hw_serial=$(adb -s "$serial" shell getprop ro.serialno 2>/dev/null | tr -d '\r' || echo "")
    os_ver=$(adb -s "$serial" shell getprop ro.build.version.lumin 2>/dev/null | tr -d '\r' || echo "")
    echo "${model}|${hw_serial}|${os_ver}"
  else
    echo "||"
  fi
}

# ── Main ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}ML Fleet Scanner${RESET}"
show_banner
echo ""

# Resolve subnet
if [[ -z "$SUBNET" ]]; then
  SUBNET=$(detect_subnet)
  echo -e "  Detected subnet: ${CYAN}${SUBNET}${RESET}"
else
  echo -e "  Using subnet:    ${CYAN}${SUBNET}${RESET}"
fi
echo -e "  Scanning port:   ${CYAN}${ADB_PORT}${RESET} (ADB)"
echo ""

# Temp dir for results
SCAN_TMP=$(mktemp -d)
FOUND_DIR="${SCAN_TMP}/found"
mkdir -p "$FOUND_DIR"
trap 'rm -rf "$SCAN_TMP"' EXIT

# Generate host list
HOSTS=$(cidr_hosts "$SUBNET")
HOST_COUNT=$(echo "$HOSTS" | wc -l | tr -d ' ')

echo -e "  Probing ${DIM}${HOST_COUNT} hosts${RESET}  ${DIM}[max ${MAX_PARALLEL} parallel]${RESET}"

# Run parallel probes
PIDS=()
RUNNING=0

while IFS= read -r ip; do
  [[ -z "$ip" ]] && continue
  probe_host "$ip" "$FOUND_DIR" &
  PIDS+=($!)
  RUNNING=$(( RUNNING + 1 ))

  # Throttle
  if (( RUNNING >= MAX_PARALLEL )); then
    wait "${PIDS[0]}" 2>/dev/null || true
    PIDS=("${PIDS[@]:1}")
    RUNNING=$(( RUNNING - 1 ))
  fi
done <<< "$HOSTS"

# Wait for remaining jobs
printf "  Scanning"
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
  printf "."
done
printf "\n\n"

# Collect found IPs (sorted)
FOUND_IPS=()
if [[ -n "$(ls "$FOUND_DIR" 2>/dev/null)" ]]; then
  while IFS= read -r ip; do
    FOUND_IPS+=("$ip")
  done < <(ls "$FOUND_DIR" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n)
fi

# ── Results ──────────────────────────────────────────────────
if [[ ${#FOUND_IPS[@]} -eq 0 ]]; then
  echo -e "  ${CROSS} No devices found on ${SUBNET}"
  echo ""
  echo -e "  ${DIM}Troubleshooting:${RESET}"
  echo -e "    • Confirm your laptop is on the same AP/subnet as the headsets"
  echo -e "    • Make sure devices have WiFi ADB enabled (port 5555)"
  echo -e "    • Try a different subnet with --subnet 10.x.x.0/24"
  echo ""
  exit 1
fi

echo -e "  ${GREEN}Found ${#FOUND_IPS[@]} device(s) with ADB port open:${RESET}"
echo ""

# Try to ADB-identify each device for display
declare -A DEVICE_INFO
for ip in "${FOUND_IPS[@]}"; do
  info=$(adb_identify "$ip" 2>/dev/null || echo "||")
  DEVICE_INFO["$ip"]="$info"
done

# Print table
printf "  ${BOLD}%-18s %-22s %-16s %-10s${RESET}\n" "IP" "Model" "Serial" "OS"
printf "  %-18s %-22s %-16s %-10s\n" "──────────────────" "──────────────────────" "────────────────" "──────────"

for ip in "${FOUND_IPS[@]}"; do
  info="${DEVICE_INFO[$ip]:-||}"
  IFS='|' read -r model hw_serial os_ver <<< "$info"
  model="${model:-unknown}"
  hw_serial="${hw_serial:-—}"
  os_ver="${os_ver:-—}"
  printf "  ${CYAN}%-18s${RESET} %-22s ${DIM}%-16s %-10s${RESET}\n" "$ip" "$model" "$hw_serial" "$os_ver"
done

echo ""

# ── Confirmation ─────────────────────────────────────────────
if ! $AUTO_YES && ! $DRY_RUN; then
  echo -e "  Write these ${#FOUND_IPS[@]} IP(s) to ${CYAN}devices/$(basename "$DEVICES_FILE")${RESET}?"
  if $APPEND; then
    echo -e "  ${DIM}(mode: append — existing entries will be kept)${RESET}"
  else
    echo -e "  ${DIM}(mode: overwrite — existing devices.txt will be replaced)${RESET}"
  fi
  echo ""
  read -rp "  [y/N] " CONFIRM
  echo ""
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "  ${DIM}Aborted — devices.txt not modified.${RESET}"
    echo ""
    exit 0
  fi
fi

if $DRY_RUN; then
  echo -e "  ${DIM}Dry run — devices.txt not modified.${RESET}"
  echo ""
  echo "  Would write:"
  for ip in "${FOUND_IPS[@]}"; do
    echo "    $ip"
  done
  echo ""
  exit 0
fi

# ── Write devices file ────────────────────────────────────────
DATESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
mkdir -p "$(dirname "$DEVICES_FILE")"

if $APPEND && [[ -f "$DEVICES_FILE" ]]; then
  # Merge: read existing (non-comment, non-blank) IPs
  EXISTING=()
  while IFS= read -r line; do
    [[ "$line" =~ ^\s*# || -z "${line// /}" ]] && continue
    EXISTING+=("$line")
  done < "$DEVICES_FILE"

  # Find new IPs not already in the file
  NEW_IPS=()
  for ip in "${FOUND_IPS[@]}"; do
    already=false
    for ex in "${EXISTING[@]}"; do
      [[ "$ex" == "$ip" ]] && already=true && break
    done
    $already || NEW_IPS+=("$ip")
  done

  if [[ ${#NEW_IPS[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}No new IPs to add — all found devices already in devices.txt${RESET}"
    echo ""
    exit 0
  fi

  {
    echo ""
    echo "# Appended by ml_scan.sh — $DATESTAMP"
    for ip in "${NEW_IPS[@]}"; do echo "$ip"; done
  } >> "$DEVICES_FILE"

  echo -e "  ${TICK} Appended ${#NEW_IPS[@]} new IP(s) to ${CYAN}${DEVICES_FILE}${RESET}"
  [[ ${#EXISTING[@]} -gt 0 ]] && \
    echo -e "  ${DIM}(${#EXISTING[@]} existing entries retained)${RESET}"

else
  # Overwrite
  {
    echo "# Generated by ml_scan.sh — $DATESTAMP"
    echo "# Subnet: $SUBNET"
    echo ""
    for ip in "${FOUND_IPS[@]}"; do echo "$ip"; done
  } > "$DEVICES_FILE"

  echo -e "  ${TICK} Wrote ${#FOUND_IPS[@]} IP(s) to ${CYAN}${DEVICES_FILE}${RESET}"
fi

echo ""
echo -e "  Next steps:"
echo -e "    ${DIM}./ml_deploy.sh connect${RESET}   — verify ADB connections"
echo -e "    ${DIM}./ml_status.sh${RESET}            — check fleet status"
echo ""
