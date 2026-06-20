#!/usr/bin/env bash
# ============================================================
# ml_show.sh — Multi-show config management — KAGAMI / Tin Drum
#
#   ./ml_show.sh                 show the active show + list all
#   ./ml_show.sh use <id>        set the active show on this machine
#   ./ml_show.sh init            interactive: create a new show
#                                 (the entire on-site setup for a
#                                  second show)
#
# This is the one tool that does NOT require a show to already
# be configured — it's how you configure one.
# ============================================================

set -euo pipefail

# bash 5+ required (macOS default 3.2 lacks mapfile et al.) — hard-stop early
source "$(dirname "${BASH_SOURCE[0]}")/lib/require_bash5.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWS_DIR="$SCRIPT_DIR/shows"
DEVICES_DIR="$SCRIPT_DIR/devices"
ACTIVE_SHOW_FILE="$SCRIPT_DIR/.active_show"
LEGACY_DEVICES="$SCRIPT_DIR/devices.txt"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
TICK="${GREEN}✓${RESET}"

active_show() {
  [[ -f "$ACTIVE_SHOW_FILE" ]] || return 0
  tr -d ' \t\r\n' < "$ACTIVE_SHOW_FILE"
}

list_shows() {
  local f found=0
  for f in "$SHOWS_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    local id; id="$(basename "$f" .conf)"
    [[ "$id" == "EXAMPLE" ]] && continue
    found=1
    if [[ "$id" == "$(active_show)" ]]; then
      echo -e "  ${GREEN}● ${id}${RESET} ${DIM}(active)${RESET}"
    else
      echo -e "  ${DIM}○${RESET} ${id}"
    fi
  done
  [[ $found -eq 0 ]] && echo -e "  ${DIM}(none — run ./ml_show.sh init)${RESET}"
}

valid_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

cmd_status() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   ML Toolkit — Shows                         ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  local cur; cur="$(active_show)"
  if [[ -n "$cur" ]]; then
    echo -e "  Active show: ${CYAN}${cur}${RESET}"
  else
    echo -e "  Active show: ${YELLOW}none set${RESET} — run ${CYAN}./ml_show.sh use <id>${RESET}"
  fi
  echo ""
  echo -e "  ${BOLD}Available:${RESET}"
  list_shows
  echo ""
}

cmd_use() {
  local id="${1:-}"
  [[ -z "$id" ]] && { echo -e "${RED}Usage: ./ml_show.sh use <id>${RESET}"; exit 1; }
  if ! valid_id "$id"; then
    echo -e "${RED}Invalid show id (allowed: letters, digits, . _ -)${RESET}"; exit 1
  fi
  if [[ ! -f "$SHOWS_DIR/$id.conf" ]]; then
    echo -e "${RED}No config at shows/$id.conf${RESET}"
    echo -e "  Create it first: ${CYAN}./ml_show.sh init${RESET}"
    exit 1
  fi
  printf '%s\n' "$id" > "$ACTIVE_SHOW_FILE"
  echo -e "  ${TICK} Active show set to ${CYAN}${id}${RESET}"

  # Offer to split the legacy fleet list into this show's file
  local per_show="$DEVICES_DIR/$id.txt"
  if [[ ! -f "$per_show" && -f "$LEGACY_DEVICES" ]]; then
    echo ""
    echo -e "  A legacy ${DIM}devices.txt${RESET} exists but ${DIM}devices/$id.txt${RESET} does not."
    read -rp "  Copy devices.txt → devices/$id.txt for this show? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      mkdir -p "$DEVICES_DIR"
      cp "$LEGACY_DEVICES" "$per_show"
      echo -e "  ${TICK} Wrote ${CYAN}devices/$id.txt${RESET} ${DIM}(devices.txt left untouched)${RESET}"
    fi
  fi
  echo ""
}

prompt_default() {
  # prompt_default "Label" "default" -> echoes the answer
  local label="$1" def="$2" ans
  if [[ -n "$def" ]]; then
    read -rp "  ${label} [${def}]: " ans
    echo "${ans:-$def}"
  else
    read -rp "  ${label}: " ans
    echo "$ans"
  fi
}

cmd_init() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   New show setup                             ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${DIM}Answer a few questions; this writes shows/<id>.conf.${RESET}"
  echo ""

  local id
  while true; do
    id="$(prompt_default "Show id (e.g. KAGAMI_BLUE)" "")"
    if [[ -z "$id" ]]; then echo -e "  ${YELLOW}Required.${RESET}"; continue; fi
    if ! valid_id "$id"; then
      echo -e "  ${YELLOW}Letters, digits, . _ - only.${RESET}"; continue
    fi
    if [[ "$id" == "EXAMPLE" ]]; then
      echo -e "  ${YELLOW}'EXAMPLE' is reserved for the template.${RESET}"; continue
    fi
    if [[ -f "$SHOWS_DIR/$id.conf" ]]; then
      read -rp "  shows/$id.conf exists — overwrite? [y/N] " ow
      [[ "$ow" =~ ^[Yy]$ ]] || continue
    fi
    break
  done

  local name ssid pass sec pkg bright data_dir data_req data_opt disk_pct eapk eos sheets_url
  name="$(prompt_default "Display name" "$id")"
  ssid="$(prompt_default "WiFi SSID" "$id")"
  while true; do
    pass="$(prompt_default "WiFi password" "")"
    [[ -n "$pass" ]] && break
    echo -e "  ${YELLOW}Required.${RESET}"
  done
  sec="$(prompt_default "WiFi security" "wpa2")"
  pkg="$(prompt_default "Show app package" "com.tindrum.kagami.red")"
  bright="$(prompt_default "Screen brightness (raw settings value)" "12")"
  data_dir="$(prompt_default "Show data dir under /sdcard/" "Kagami")"
  data_req="$(prompt_default "Required entries under data dir (space-sep)" "data")"
  data_opt="$(prompt_default "Optional entries (runtime-created, space-sep)" "applogs textures config.json marker-space-config.json")"
  disk_pct="$(prompt_default "Disk-usage warn threshold (%)" "60")"
  eapk="$(prompt_default "Expected APK version (blank to skip check)" "")"
  eos="$(prompt_default "Expected OS version (blank to skip check)" "")"
  sheets_url="$(prompt_default "Google Apps Script URL for this show's sheet (blank to skip)" "")"

  mkdir -p "$SHOWS_DIR"
  cat > "$SHOWS_DIR/$id.conf" <<EOF
# ============================================================
# Show config: $id
# Created by ml_show.sh init on $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

SHOW_NAME="$name"

SHOW_SSID="$ssid"
SHOW_WIFI_PASSWORD="$pass"
SHOW_WIFI_SECURITY="$sec"

SHOW_PACKAGE="$pkg"

SHOW_BRIGHTNESS="$bright"

SHOW_DATA_DIR="$data_dir"
SHOW_DATA_REQUIRED="$data_req"
SHOW_DATA_OPTIONAL="$data_opt"
SHOW_DISK_WARN_PCT="$disk_pct"

SHOW_EXPECTED_APK="$eapk"
SHOW_EXPECTED_OS="$eos"

SHOW_SHEETS_URL="$sheets_url"
EOF

  echo ""
  echo -e "  ${TICK} Wrote ${CYAN}shows/$id.conf${RESET}"
  echo ""
  read -rp "  Make '$id' the active show now? [Y/n] " mk
  if [[ ! "$mk" =~ ^[Nn]$ ]]; then
    cmd_use "$id"
  else
    echo -e "  ${DIM}Later: ./ml_show.sh use $id${RESET}"
    echo ""
  fi
}

case "${1:-status}" in
  status|"")    cmd_status ;;
  use)          shift; cmd_use "${1:-}" ;;
  init)         cmd_init ;;
  -h|--help)
    echo "Usage: ./ml_show.sh [status | use <id> | init]"
    ;;
  *) echo -e "${RED}Unknown command: $1${RESET}"
     echo "Usage: ./ml_show.sh [status | use <id> | init]"; exit 1 ;;
esac
