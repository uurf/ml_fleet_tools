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
    # No $ML_SHOW and no .active_show. Don't force a separate
    # `./ml_show.sh use` — resolve here instead:
    #   0 shows      → die (must create one)
    #   exactly 1    → use it (unambiguous; safe even for --json)
    #   >=2 + a TTY  → numbered menu, then continue this run
    #   >=2 + no TTY → die (keeps --json / fleet workers non-blocking;
    #                  read prompt goes to stderr, picker exits rather
    #                  than emitting partial machine-readable output)
    local _shows=() _f _b
    for _f in "$SHOWS_DIR"/*.conf; do
      [[ -f "$_f" ]] || continue
      _b="$(basename "$_f" .conf)"
      [[ "$_b" == "EXAMPLE" ]] && continue
      _shows+=("$_b")
    done

    if [[ ${#_shows[@]} -eq 0 ]]; then
      _sc_die "No show configured."
    elif [[ ${#_shows[@]} -eq 1 ]]; then
      show_id="${_shows[0]}"
      echo -e "${DIM}  Only one show configured (${show_id}) — using it.${RESET}" >&2
    elif [[ -t 0 && -t 1 ]]; then
      echo "" >&2
      echo -e "  ${BOLD}Select a show:${RESET}" >&2
      local _i=1
      for _b in "${_shows[@]}"; do
        echo -e "    [$_i] ${_b}" >&2
        _i=$((_i+1))
      done
      local _sel=""
      read -rp "  Select [1-${#_shows[@]}]: " _sel </dev/tty
      if [[ ! "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > ${#_shows[@]} )); then
        _sc_die "Invalid selection."
      fi
      show_id="${_shows[$((_sel-1))]}"
      printf '%s\n' "$show_id" > "$ACTIVE_SHOW_FILE"
      echo -e "  ${GREEN}Using ${BOLD}${show_id}${RESET}${GREEN} — saved as the active show on this machine.${RESET}" >&2
      echo "" >&2
    else
      _sc_die "No active show set, and multiple shows exist (non-interactive)."
    fi
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
  [[ -z "${SHOW_SSID:-}" ]]            && missing+=("SHOW_SSID")
  [[ -z "${SHOW_WIFI_PASSWORD:-}" ]]   && missing+=("SHOW_WIFI_PASSWORD")
  [[ -z "${SHOW_WIFI_SECURITY:-}" ]]   && missing+=("SHOW_WIFI_SECURITY")
  [[ -z "${SHOW_PACKAGE:-}" ]]         && missing+=("SHOW_PACKAGE")
  [[ -z "${SHOW_BRIGHTNESS:-}" ]]      && missing+=("SHOW_BRIGHTNESS")
  [[ -z "${SHOW_DATA_DIR:-}" ]]        && missing+=("SHOW_DATA_DIR")
  [[ -z "${SHOW_DISK_WARN_PCT:-}" ]]   && missing+=("SHOW_DISK_WARN_PCT")
  if [[ ${#missing[@]} -gt 0 ]]; then
    _sc_die "shows/$show_id.conf is missing required field(s): ${missing[*]}"
  fi

  # 5. Defaults for optional fields
  : "${SHOW_NAME:=$show_id}"
  : "${SHOW_EXPECTED_APK:=}"
  : "${SHOW_EXPECTED_OS:=}"
  # Expected kiosk (com.tindrum.kiosk) versionName — EXACT match (drift/build
  # check). Pin to the current build (e.g. "1.3r") to flag out-of-date kiosks;
  # leave blank during build churn to skip the exact check. See SHOW_KIOSK_SUFFIX
  # for the (stable) wrong-show check that works even while this is blank.
  : "${SHOW_KIOSK_VERSION:=}"
  # Kiosk versionName show-marker suffix — the kiosk is ONE shared package
  # (com.tindrum.kiosk), so the per-show letter on its versionName is the only
  # way to tell a RED kiosk from a BLUE one on a device. Scheme: "1.Xr" (RED) /
  # "1.Xb" (BLUE) — X increments per build, suffix marks the show. ml_status
  # enforces "versionName ends with this suffix" ALWAYS (independent of the
  # blank-able SHOW_KIOSK_VERSION), so a mis-loaded kiosk is caught mid-churn.
  # Blank skips the wrong-show check.
  : "${SHOW_KIOSK_SUFFIX:=}"
  # Packages belonging to OTHER shows that must be uninstalled when
  # provisioning this show (space-separated). E.g. KAGAMI_BLUE removes the
  # RED show app com.tindrum.kagamu so a re-purposed device doesn't carry a
  # foreign show app. ml_provision.sh seeds REMOVE_PACKAGES from this; applied
  # only in the provision pass, never in --check. Blank = remove nothing extra.
  : "${SHOW_REMOVE_PACKAGES:=}"
  # CIDR subnet ml_scan probes for this show (e.g. 172.16.40.0/22). Blank =
  # auto-detect. Set it to avoid under-scanning when the network is wider than
  # a /24 (this fleet is a /22). --subnet on the CLI still overrides.
  : "${SHOW_SUBNET:=}"
  # Google Apps Script web app URL for this show's tracking sheet. Each
  # show has its own bound workbook + deployment (see apps_script/Code.gs
  # header). Blank = no sheet sync for this show (update_sheet no-ops).
  : "${SHOW_SHEETS_URL:=}"
  # Names (files or dirs) under /sdcard/$SHOW_DATA_DIR/ that must
  # be present. Their absence is dashboard trouble.
  : "${SHOW_DATA_REQUIRED:=data}"
  # Names (files or dirs) under /sdcard/$SHOW_DATA_DIR/ that the
  # show APK creates at runtime (logs, runtime caches, registered
  # apriltag config). Their absence is fine — a bench-provisioned
  # device that has not yet run the show won't have them yet.
  # Anything found under the data dir that is NOT in
  # SHOW_DATA_REQUIRED ∪ SHOW_DATA_OPTIONAL is extraneous.
  : "${SHOW_DATA_OPTIONAL:=applogs textures config.json marker-space-config.json}"

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

  # 6b. Inventory file — the canonical per-show roster (Device,Serial): the
  # expected device inventory the dashboard loads to flag missing devices, and
  # the device#↔serial map. Written by build_canonical_map.py from the scans;
  # rows moved between shows by ml_show_migrate. Falls back to the legacy
  # fleet-wide asset_serial_list.csv until the per-show files exist.
  SHOW_INVENTORY_FILE_DEFAULT="$TOOLKIT_ROOT/inventory/$show_id.csv"
  local legacy_inv="$TOOLKIT_ROOT/asset_serial_list.csv"
  if [[ -f "$SHOW_INVENTORY_FILE_DEFAULT" ]]; then
    SHOW_INVENTORY_FILE="$SHOW_INVENTORY_FILE_DEFAULT"
  elif [[ -f "$legacy_inv" ]]; then
    SHOW_INVENTORY_FILE="$legacy_inv"
  else
    SHOW_INVENTORY_FILE="$SHOW_INVENTORY_FILE_DEFAULT"
  fi

  # Canonical device→show registry (registry.gs web app) — the single, dedicated
  # serial→show store, SHARED across shows (the registry has a Show column; one
  # URL for all shows, unlike the per-show tracker sheets in SHOW_SHEETS_URL).
  # Env-overridable; blank disables registry posting. Wired into ml_provision
  # (provision_complete) so every commissioned/migrated device records itself.
  : "${SHOW_REGISTRY_URL:=https://script.google.com/macros/s/AKfycbxdvol0CF2zt7mKvyGiNqnCAFuioRJsu7Mycfm8onHOzbgyTbdYBUwVZSDYLnWSiW88/exec}"

  ML_SHOW="$show_id"
  export ML_SHOW SHOW_NAME SHOW_SSID SHOW_WIFI_PASSWORD SHOW_WIFI_SECURITY \
         SHOW_PACKAGE SHOW_EXPECTED_APK SHOW_EXPECTED_OS SHOW_KIOSK_VERSION \
         SHOW_KIOSK_SUFFIX SHOW_REMOVE_PACKAGES SHOW_SUBNET SHOW_BRIGHTNESS SHOW_SHEETS_URL \
         SHOW_REGISTRY_URL \
         SHOW_DATA_DIR SHOW_DATA_REQUIRED SHOW_DATA_OPTIONAL SHOW_DISK_WARN_PCT \
         SHOW_DEVICES_FILE SHOW_DEVICES_FILE_DEFAULT \
         SHOW_INVENTORY_FILE SHOW_INVENTORY_FILE_DEFAULT
}

# Upsert a device's show membership into the canonical registry (registry.gs).
# registry_upsert <serial> <show> [device#] [status] [source]
# No-op if SHOW_REGISTRY_URL is blank. Unlike update_sheet(), this WARNS on
# failure (stderr) instead of silently swallowing it — a failed registry write
# should be visible so the operator can re-run.
registry_upsert() {
  [[ -z "${SHOW_REGISTRY_URL:-}" ]] && return 0
  local serial="$1" show="$2" device="${3:-}" status="${4:-active}" source="${5:-provision}"
  local GREEN="${GREEN:-}" YELLOW="${YELLOW:-}" DIM="${DIM:-}" RESET="${RESET:-}"
  if [[ -z "$serial" ]]; then
    echo -e "  ${YELLOW}⚠ registry: empty serial — skipped${RESET}" >&2; return 0
  fi
  local out rc
  out=$(REG_URL="$SHOW_REGISTRY_URL" SERIAL="$serial" SHOW="$show" DEVICE="$device" \
        STATUS="$status" SOURCE="$source" python3 -c '
import urllib.request, json, os, sys
data=json.dumps({"serial":os.environ["SERIAL"],"show":os.environ["SHOW"],
                 "device":os.environ["DEVICE"],"status":os.environ["STATUS"],
                 "source":os.environ["SOURCE"]}).encode()
req=urllib.request.Request(os.environ["REG_URL"], data=data,
                           headers={"Content-Type":"application/json"})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=15).read().decode())
except Exception as e:
    sys.stderr.write("ERR:"+str(e)); sys.exit(1)
' 2>&1) && rc=0 || rc=$?
  if [[ $rc -eq 0 && "$out" == *'"ok":true'* ]]; then
    echo -e "  ${GREEN}✓${RESET} registry: $serial → $show ${DIM}(device ${device:-?})${RESET}" >&2
  else
    echo -e "  ${YELLOW}⚠ registry update FAILED for $serial${RESET} — ${out}" >&2
    echo -e "    ${DIM}re-run, or POST {serial,show} to the registry manually${RESET}" >&2
  fi
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

# List the available show configs and let the operator switch.
# Sets .active_show and aborts so the command is re-run cleanly:
# callers snapshot SHOW_* before show_confirm, so swapping config
# mid-run would leave stale values (unsafe for a destructive flash).
_sc_pick_show() {
  local shows=() f b i=1
  for f in "$SHOWS_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f" .conf)"
    [[ "$b" == "EXAMPLE" ]] && continue
    shows+=("$b")
  done
  if [[ ${#shows[@]} -eq 0 ]]; then
    echo -e "  ${RED}No show configs in shows/ — run ./ml_show.sh init${RESET}" >&2
    return 0
  fi
  echo ""
  echo -e "  ${BOLD}Available show configurations:${RESET}"
  for b in "${shows[@]}"; do
    if [[ "$b" == "$ML_SHOW" ]]; then
      echo -e "    [$i] ${b} ${DIM}(current)${RESET}"
    else
      echo -e "    [$i] ${b}"
    fi
    i=$((i+1))
  done
  local sel=""
  read -rp "  Select [1-${#shows[@]}], or Enter to cancel: " sel </dev/tty
  [[ -z "$sel" ]] && return 0
  if [[ ! "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#shows[@]} )); then
    echo -e "  ${YELLOW}Invalid selection.${RESET}"
    return 0
  fi
  local chosen="${shows[$((sel-1))]}"
  printf '%s\n' "$chosen" > "$ACTIVE_SHOW_FILE"
  echo ""
  echo -e "  ${GREEN}Active show set to ${BOLD}${chosen}${RESET}${GREEN}.${RESET}  ${CYAN}Re-run the command${RESET} to continue."
  echo ""
  exit 0
}

# Confirm the resolved show before a show-affecting action.
# No-ops when a parent in the chain already confirmed. Enter
# proceeds (low per-device overhead); S switches show config.
show_confirm() {
  local action="${1:-this operation}"
  if [[ "${ML_SHOW_CONFIRMED:-}" == "1" ]]; then
    return 0
  fi
  show_banner
  echo ""
  echo -e "  ${YELLOW}About to ${action} for the ${BOLD}${SHOW_NAME}${RESET}${YELLOW} fleet.${RESET}"
  echo ""
  local ans=""
  while true; do
    read -rp "  Press Enter to continue, or S for other available show configurations: " ans </dev/tty
    case "$ans" in
      ""|[Yy]) export ML_SHOW_CONFIRMED=1; echo ""; return 0 ;;
      [Ss])    _sc_pick_show ;;
      *)       echo -e "  ${DIM}Enter = continue · S = choose another show${RESET}" ;;
    esac
  done
}

_sc_init || exit 1
