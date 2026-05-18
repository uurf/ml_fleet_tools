#!/usr/bin/env bash
# ============================================================
# Multi-show config resolver — KAGAMI / Tin Drum
#
# Sourced by every main script. Resolves which show is active,
# loads shows/<id>.conf, and exports SHOW_* + SHOW_DEVICES_FILE
# so the rest of the toolkit is show-agnostic.
#
# Active show is resolved in this order:
#   1. $ML_SHOW          (set by --show, or inherited down the
#                          flash → provision → deploy chain)
#   2. .active_show file  (set once on a machine via ./ml_show.sh use)
#   3. (none) → hard stop with instructions
#
# A show id only proves a show was configured when the conf was
# written; the conf is the source of truth and is validated here.
# ============================================================

# Resolve repo root from THIS file's location (lib/ is at the
# repo root), so it works whether sourced from / or utilities/.
_SC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(dirname "$_SC_LIB_DIR")"
SHOWS_DIR="$TOOLKIT_ROOT/shows"
ACTIVE_SHOW_FILE="$TOOLKIT_ROOT/.active_show"

# Colors (only define if the sourcing script hasn't already)
: "${RED:=$'\033[0;31m'}"; : "${GREEN:=$'\033[0;32m'}"
: "${YELLOW:=$'\033[1;33m'}"; : "${CYAN:=$'\033[0;36m'}"
: "${BOLD:=$'\033[1m'}"; : "${DIM:=$'\033[2m'}"; : "${RESET:=$'\033[0m'}"

_sc_available_shows() {
  local f
  for f in "$SHOWS_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    local b; b="$(basename "$f" .conf)"
    [[ "$b" == "EXAMPLE" ]] && continue
    echo "  • $b"
  done
}

_sc_die() {
  echo "" >&2
  echo -e "${RED}┌─────────────────────────────────────────────────┐${RESET}" >&2
  echo -e "${RED}│  No show configured — cannot continue            │${RESET}" >&2
  echo -e "${RED}└─────────────────────────────────────────────────┘${RESET}" >&2
  echo "" >&2
  echo -e "  $1" >&2
  echo "" >&2
  local list; list="$(_sc_available_shows)"
  if [[ -n "$list" ]]; then
    echo -e "  Available shows:" >&2
    echo -e "$list" >&2
    echo "" >&2
    echo -e "  Select one:  ${CYAN}./ml_show.sh use <id>${RESET}" >&2
  else
    echo -e "  Create one:  ${CYAN}./ml_show.sh init${RESET}" >&2
  fi
  echo "" >&2
  exit 1
}

_sc_init() {
  # 1. Resolve the show id
  local show_id="${ML_SHOW:-}"
  if [[ -z "$show_id" && -f "$ACTIVE_SHOW_FILE" ]]; then
    show_id="$(tr -d ' \t\r\n' < "$ACTIVE_SHOW_FILE")"
  fi
  if [[ -z "$show_id" ]]; then
    _sc_die "No active show set (\$ML_SHOW unset and no .active_show file)."
  fi

  # 2. Reject anything that could escape the shows/ directory
  if [[ ! "$show_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    _sc_die "Invalid show id: '$show_id' (allowed: letters, digits, . _ -)."
  fi

  # 3. Load the conf
  local conf="$SHOWS_DIR/$show_id.conf"
  if [[ ! -f "$conf" ]]; then
    _sc_die "Show '$show_id' has no config file at shows/$show_id.conf"
  fi
  # shellcheck disable=SC1090
  source "$conf"

  # 4. Validate required fields
  local missing=()
  [[ -z "${SHOW_SSID:-}" ]]          && missing+=("SHOW_SSID")
  [[ -z "${SHOW_WIFI_PASSWORD:-}" ]] && missing+=("SHOW_WIFI_PASSWORD")
  [[ -z "${SHOW_WIFI_SECURITY:-}" ]] && missing+=("SHOW_WIFI_SECURITY")
  [[ -z "${SHOW_PACKAGE:-}" ]]       && missing+=("SHOW_PACKAGE")
  if [[ ${#missing[@]} -gt 0 ]]; then
    _sc_die "shows/$show_id.conf is missing required field(s): ${missing[*]}"
  fi

  # 5. Defaults for optional fields
  : "${SHOW_NAME:=$show_id}"
  : "${SHOW_EXPECTED_APK:=}"
  : "${SHOW_EXPECTED_OS:=}"

  # 6. Devices file.
  #  - SHOW_DEVICES_FILE_DEFAULT: canonical per-show path; what
  #    ml_scan.sh / ml_show.sh WRITE to.
  #  - SHOW_DEVICES_FILE: what scripts READ. Prefers the per-show
  #    file; falls back to legacy devices.txt so the live fleet
  #    keeps working until it's been split per-show.
  SHOW_DEVICES_FILE_DEFAULT="$TOOLKIT_ROOT/devices/$show_id.txt"
  local legacy="$TOOLKIT_ROOT/devices.txt"
  if [[ -f "$SHOW_DEVICES_FILE_DEFAULT" ]]; then
    SHOW_DEVICES_FILE="$SHOW_DEVICES_FILE_DEFAULT"
  elif [[ -f "$legacy" ]]; then
    SHOW_DEVICES_FILE="$legacy"
    if [[ -z "${ML_SHOW_CONFIRMED:-}" && -z "${FLEET_WORKER:-}" ]]; then
      echo -e "${DIM}  (using legacy devices.txt — ./ml_show.sh use $show_id splits it per-show)${RESET}" >&2
    fi
  else
    SHOW_DEVICES_FILE="$SHOW_DEVICES_FILE_DEFAULT"
  fi

  ML_SHOW="$show_id"
  export ML_SHOW SHOW_NAME SHOW_SSID SHOW_WIFI_PASSWORD SHOW_WIFI_SECURITY \
         SHOW_PACKAGE SHOW_EXPECTED_APK SHOW_EXPECTED_OS \
         SHOW_DEVICES_FILE SHOW_DEVICES_FILE_DEFAULT
}

# Print the resolved show. Safe for read-only scripts.
show_banner() {
  local dev_disp; dev_disp="$(basename "$SHOW_DEVICES_FILE")"
  local n="?"
  [[ -f "$SHOW_DEVICES_FILE" ]] && \
    n="$(grep -cvE '^\s*(#|$)' "$SHOW_DEVICES_FILE" 2>/dev/null || echo 0)"
  echo ""
  echo -e "  ${BOLD}Show:${RESET} ${CYAN}${SHOW_NAME}${RESET} ${DIM}(${ML_SHOW})${RESET}"
  echo -e "  ${DIM}SSID ${SHOW_SSID} · pkg ${SHOW_PACKAGE} · devices ${dev_disp} (${n})${RESET}"
}

# Require typed confirmation before a show-affecting action.
# No-ops when a parent in the chain already confirmed.
show_confirm() {
  local action="${1:-this operation}"
  if [[ "${ML_SHOW_CONFIRMED:-}" == "1" ]]; then
    return 0
  fi
  show_banner
  echo ""
  echo -e "  ${YELLOW}About to ${action} for the ${BOLD}${SHOW_NAME}${RESET}${YELLOW} fleet.${RESET}"
  echo -e "  ${DIM}If that is the wrong show: Ctrl+C, then ./ml_show.sh use <id>${RESET}"
  echo ""
  local typed=""
  read -rp "  Type the show id ('${ML_SHOW}') to continue: " typed
  if [[ "$typed" != "$ML_SHOW" ]]; then
    echo -e "  ${RED}Show id did not match — aborting.${RESET}" >&2
    exit 1
  fi
  export ML_SHOW_CONFIRMED=1
  echo ""
}

_sc_init || exit 1
