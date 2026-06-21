#!/usr/bin/env bash
# ============================================================
# Magic Leap 2 Fleet Deploy Tool — KAGAMI / Tin Drum
# Usage: ./ml_deploy.sh [command] [options]
# Requires Homebrew bash 5+ (macOS default 3.2 lacks mapfile).
# ============================================================

set -euo pipefail

# bash 5+ required (macOS default 3.2 lacks mapfile et al.) — hard-stop early
source "$(dirname "${BASH_SOURCE[0]}")/lib/require_bash5.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="$SCRIPT_DIR/devices.txt"
LOG_DIR="$SCRIPT_DIR/logs"
BUILDS_DIR="$SCRIPT_DIR/builds"
MAX_PARALLEL=20  # tune based on your network/router limits

mkdir -p "$LOG_DIR"

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

usage() {
  echo ""
  echo -e "${BOLD}ML Fleet Deploy — Tin Drum${RESET}"
  echo -e "${DIM}  $TOOLKIT_VERSION${RESET}"
  echo ""
  echo "  Commands:"
  echo "    deploy                Select APK(s) from builds/ and push assets + install"
  echo "    connect               Connect to all devices over WiFi ADB"
  echo "    status                Show online/offline status of all devices"
  echo "    install <path.apk>    Install APK to all online devices"
  echo "    push <src> <dest>     Push file/folder to all devices"
  echo "    launch <package>      Launch app on all devices"
  echo "    stop <package>        Stop app on all devices"
  echo "    restart <package>     Stop then launch app on all devices"
  echo "    reboot                Reboot all devices"
  echo "    shutdown              Power off all devices (nightly end-of-day)"
  echo "    locate <ip>          Beep a device repeatedly to find it physically (non-destructive)"
  echo "    shell <cmd>           Run any adb shell command on all devices"
  echo "    logs <package>        Stream logcat for a package from all devices"
  echo ""
  echo "  Options:"
  echo "    -d <ip>               Target a single device by IP"
  echo "    -f <file>             Use alternate devices file (default: devices.txt)"
  echo "    -j <n>                Max parallel jobs (default: $MAX_PARALLEL)"
  echo ""
  echo "  Examples:"
  echo "    ./ml_deploy.sh deploy"
  echo "    ./ml_deploy.sh -d 192.168.1.45 deploy"
  echo "    ./ml_deploy.sh install builds/<show>_v2.apk"
  echo "    ./ml_deploy.sh push assets/ /sdcard/<SHOW_DATA_DIR>/"
  echo "    ./ml_deploy.sh restart <show app package>"
  echo "    ./ml_deploy.sh shell 'pm list packages'"
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
  local total; total=$(printf '%s\n' "$devices" | grep -c . || true)

  # Phase 1: bounded, parallel reachability probe. A bare `adb connect` to a
  # powered-off IP hangs on the OS TCP timeout (~60s on macOS) — and serially
  # that's ~an hour for a fleet with many off. Probe port 5555 first with a
  # 2s-bounded nc (-G = connect timeout, macOS) so dead IPs are skipped fast,
  # then only `adb connect` the ones that answer.
  local alive_dir; alive_dir=$(mktemp -d)
  local pids=() running=0
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    { nc -z -G 2 -w 2 "$ip" 5555 >/dev/null 2>&1 && echo "$ip" > "$alive_dir/$ip"; } &
    pids+=($!); ((running++)) || true
    if (( running >= MAX_PARALLEL )); then
      wait "${pids[0]}" 2>/dev/null || true; pids=("${pids[@]:1}"); ((running--)) || true
    fi
  done <<< "$devices"
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  # Phase 2: adb connect only the reachable IPs (port already open → fast).
  local count=0 failed=0 alive=0
  for ipf in "$alive_dir"/*; do
    [[ -e "$ipf" ]] || continue
    ((alive++)) || true
    local ip; ip=$(basename "$ipf")
    if adb connect "${ip}:5555" 2>&1 | grep -q "connected"; then
      echo -e "  ${GREEN}✓${RESET} $ip"; ((count++)) || true
    else
      echo -e "  ${RED}✗${RESET} $ip (port open, adb connect failed)"; ((failed++)) || true
    fi
  done
  rm -rf "$alive_dir"
  echo ""
  echo -e "Connected: ${GREEN}$count${RESET}  Failed: ${RED}$failed${RESET}  Offline (skipped): ${DIM}$((total-alive))${RESET}"
}

# ---- Get list of currently connected ADB devices ----
online_devices() {
  adb devices | grep -v "List of" | grep "device$" | awk '{print $1}' || true
}

# ---- Status check ----
cmd_status() {
  show_banner
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

    # Throttle parallelism. Reap finished jobs here too — and PRINT + count
    # them (the old version counted silently, so jobs that completed during
    # throttling never showed and the totals didn't add up to the device count).
    while (( running >= MAX_PARALLEL )); do
      for i in "${!pids[@]}"; do
        if ! kill -0 "${pids[$i]}" 2>/dev/null; then
          local rserial="${serials[$i]}"
          local rlog="$LOG_DIR/${timestamp}_${rserial//:/_}.log"
          if wait "${pids[$i]}"; then
            echo -e "  ${GREEN}✓${RESET} $rserial"
            ((success++)) || true
          else
            local rwhy=""
            rwhy=$(grep -iE "Failure|INSTALL_FAILED|adb: |signatures do not match|error" "$rlog" 2>/dev/null | tail -1) || true
            [[ -n "$rwhy" ]] || rwhy=$(grep -v '^[[:space:]]*$' "$rlog" 2>/dev/null | tail -1) || true
            echo -e "  ${RED}✗${RESET} $rserial — $rwhy"
            ((fail++)) || true
          fi
          unset 'pids[$i]'
          unset 'serials[$i]'
          ((running--)) || true
        fi
      done
      sleep 0.1
    done

    "$cmd_fn" "$serial" "$@" </dev/null > "$logfile" 2>&1 &   # </dev/null: adb shell must not eat the loop's device list
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
      # Surface the actual failure, not a trailing blank line. The `|| true`
      # guards are required: grep returns non-zero when nothing matches, which
      # under `set -o pipefail` would otherwise abort the whole run right here.
      local why=""
      why=$(grep -iE "Failure|INSTALL_FAILED|adb: |signatures do not match|error" "$logfile" 2>/dev/null | tail -1) || true
      [[ -n "$why" ]] || why=$(grep -v '^[[:space:]]*$' "$logfile" 2>/dev/null | tail -1) || true
      echo -e "  ${RED}✗${RESET} $serial — $why"
      ((fail++)) || true
    fi
  done

  echo ""
  echo -e "Done — Success: ${GREEN}$success${RESET}  Failed: ${RED}$fail${RESET}"
  echo -e "Logs: $LOG_DIR/"
}

# ---- Per-device operations ----
do_install() {
  # Every capture below is `|| true`-guarded: adb/grep return non-zero on
  # failure/no-match, and under the script's `set -euo pipefail` an
  # unguarded `x=$(failing | pipe)` aborts the whole run here. Status is
  # derived from the "Success" text, not exit codes.
  local s="$1" apk="$2" out pkg
  # Normal replace. -d also clears a version-downgrade conflict in place,
  # keeping app data (no uninstall needed for that case).
  out=$(adb -s "$s" install -r -d -g "$apk" 2>&1) || true
  if printf '%s' "$out" | grep -q "Success"; then printf '%s\n' "$out"; return 0; fi

  # A signature mismatch can't be replaced in place — e.g. a com.tindrum.kiosk
  # written with a non-fleet key. Pull the conflicting package out of adb's
  # error, uninstall it, and reinstall this build. Only triggers on the
  # signature case, so a fleet-key app just updates above without an uninstall.
  if printf '%s' "$out" | grep -qiE "signatures do not match|INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
    pkg=$(printf '%s' "$out" | grep -oiE "package [a-z0-9_.]+" | head -1 | awk '{print $2}') || true
    [[ -n "$pkg" ]] || pkg=$(printf '%s' "$out" | grep -oE "com\.[a-z0-9_.]+" | head -1) || true
    if [[ -n "$pkg" ]]; then
      printf 'signature mismatch on %s — uninstalling and reinstalling\n' "$pkg"
      adb -s "$s" uninstall "$pkg" >/dev/null 2>&1 || true
      out=$(adb -s "$s" install -r -g "$apk" 2>&1) || true
      printf '%s\n' "$out"
      printf '%s' "$out" | grep -q "Success" && return 0 || return 1
    fi
  fi
  printf '%s\n' "$out"
  return 1
}
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
do_shutdown(){ local s="$1"; adb -s "$s" shell reboot -p 2>/dev/null || adb -s "$s" shell svc power shutdown; }

# Reliable fleet shutdown: probe → connect → power off → re-probe → retry.
# The old path (run_parallel do_shutdown) only hit already-connected devices and
# never verified, so a device whose WiFi adb session had lapsed was silently
# skipped (the "5 didn't shut down, did on a second run" symptom). This re-probes
# port 5555 after each pass and retries stragglers until none answer (or max
# passes), so one command actually powers the fleet down.
cmd_shutdown() {
  local ips
  if [[ -n "${SINGLE_DEVICE:-}" ]]; then
    ips="${SINGLE_DEVICE%%:*}"            # -d <ip>: just that device
  else
    ips=$(load_devices)                   # whole fleet from the device file
  fi
  if [[ -z "$ips" ]]; then echo -e "${RED}No devices to shut down.${RESET}"; exit 1; fi
  local max_tries=4 try=1

  # bounded parallel probe of port 5555 across the device list -> echoes alive IPs
  _alive_ips() {
    local d; d=$(mktemp -d); local p=() r=0 ip
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      { nc -z -G 2 -w 2 "$ip" 5555 >/dev/null 2>&1 && echo "$ip" >"$d/$ip"; } </dev/null &
      p+=($!); ((r++)) || true
      if (( r >= MAX_PARALLEL )); then wait "${p[0]}" 2>/dev/null || true; p=("${p[@]:1}"); ((r--)) || true; fi
    done <<< "$ips"
    for _pp in "${p[@]}"; do wait "$_pp" 2>/dev/null || true; done
    ls "$d" 2>/dev/null
    rm -rf "$d"
  }

  while (( try <= max_tries )); do
    local alive; alive=$(_alive_ips)
    local n; n=$(printf '%s\n' "$alive" | grep -c . || true)
    if (( n == 0 )); then
      echo -e "  ${GREEN}✓ All devices powered off.${RESET}"
      return 0
    fi
    echo -e "${CYAN}Pass $try — $n device(s) still up; powering off...${RESET}"
    local sp=() sr=0 ip
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      { adb connect "${ip}:5555" >/dev/null 2>&1 || true; do_shutdown "${ip}:5555" >/dev/null 2>&1 || true; echo -e "  ${DIM}↓ $ip${RESET}"; } </dev/null &
      sp+=($!); ((sr++)) || true
      if (( sr >= MAX_PARALLEL )); then wait "${sp[0]}" 2>/dev/null || true; sp=("${sp[@]:1}"); ((sr--)) || true; fi
    done <<< "$alive"
    for _pp in "${sp[@]}"; do wait "$_pp" 2>/dev/null || true; done
    sleep 8   # let devices drop off WiFi before re-probing
    ((try++)) || true
  done

  local left; left=$(_alive_ips); local nl; nl=$(printf '%s\n' "$left" | grep -c . || true)
  if (( nl > 0 )); then
    echo -e "${YELLOW}⚠ $nl device(s) still responding after $max_tries passes — check physically:${RESET}"
    printf '    %s\n' $left
    return 1
  fi
  echo -e "  ${GREEN}✓ All devices powered off.${RESET}"
}
do_shell()   { local s="$1"; shift; adb -s "$s" shell "$@"; }

# Audible locate: post N notifications (distinct tags so each re-alerts) on the
# device — the only sound path reachable from adb shell on the locked ML2 user
# build (no tinyplay; media-intent has no kiosk handler). Non-destructive: no
# shutdown/reboot, no re-power. A unique tag per beep forces the chime each time
# (same tag updates silently). Bumps the notification stream first.
do_locate() {
  local s="$1" n="${2:-6}" i
  adb -s "$s" shell media volume --stream 5 --set 7 >/dev/null 2>&1 || true
  for (( i=1; i<=n; i++ )); do
    adb -s "$s" shell cmd notification post -S bigtext "mllocate$i" "LOCATE BEEP $i" >/dev/null 2>&1 || true
    sleep 1
  done
}

# Set the kiosk as the launcher/home. ML2 ships THREE HOME-category
# activities (com.magicleap.homemenu, the kiosk, settings/.FallbackHome);
# set-home-activity only picks the *preferred* one. Two traps:
#   1. `adb shell` does not propagate the inner exit code on ML2, so a
#      failed set-home-activity still looks like success.
#   2. PackageManager persists the preference on a delayed writer — the
#      post-install reboot (#36) can interrupt before it sticks.
# So we verify it actually resolves before returning success; the caller
# then settles before rebooting. Returns non-zero (real ✗) if it didn't.
do_set_home() {
  local s="$1" comp="com.tindrum.kiosk/.MainActivity" out resolved i
  if [[ -z "$(adb -s "$s" shell pm path com.tindrum.kiosk 2>/dev/null | tr -d '\r')" ]]; then
    echo "com.tindrum.kiosk not installed — cannot set home"
    return 1
  fi
  out=$(adb -s "$s" shell cmd package set-home-activity "$comp" 2>&1 | tr -d '\r')
  for i in 1 2 3 4 5 6 7 8 9 10; do
    resolved=$(adb -s "$s" shell cmd package resolve-activity --brief \
                 -a android.intent.action.MAIN \
                 -c android.intent.category.HOME 2>/dev/null \
                 | tr -d '\r' | tail -1)
    if [[ "$resolved" == com.tindrum.kiosk/* ]]; then
      adb -s "$s" shell sync 2>/dev/null || true
      return 0
    fi
    sleep 1
  done
  echo "home still resolves to '${resolved:-?}' (set-home said: ${out:-no output})"
  return 1
}

# ---- Wrapper functions for export (needed for run_parallel subshell) ----
export -f do_install do_push do_launch do_stop do_restart do_reboot do_shutdown do_shell do_set_home do_locate 2>/dev/null || true

# Connect to one device and beep it repeatedly so an operator can find it
# physically. Resolves its device# from the show inventory for the prompt.
cmd_locate() {
  local ip="${1%%:*}"
  [[ -z "$ip" ]] && { echo -e "${RED}Usage: ml_deploy.sh locate <ip>${RESET}"; exit 1; }
  local serial="${ip}:5555"
  adb connect "$serial" >/dev/null 2>&1 || true
  if ! adb devices | grep -qE "^${serial}[[:space:]].*device$"; then
    echo -e "${RED}✗ $ip not reachable/authorized — can't beep (unauthed devices can't run shell).${RESET}"
    echo -e "  ${DIM}For an unauthed device, shut down the others instead and find the one still on.${RESET}"
    exit 1
  fi
  # Best-effort device# lookup from the inventory (Device,Serial)
  local hw dev=""
  hw=$(adb -s "$serial" shell getprop ro.serialno 2>/dev/null | tr -d '\r') || true
  if [[ -n "$hw" && -f "${SHOW_INVENTORY_FILE:-}" ]]; then
    dev=$(awk -F, -v s="$hw" 'BEGIN{IGNORECASE=1}{gsub(/\r/,"")} toupper($2)==toupper(s){print $1; exit}' "$SHOW_INVENTORY_FILE") || true
  fi
  echo -e "${CYAN}Beeping ${BOLD}$ip${RESET}${CYAN}${hw:+  ($hw)}${dev:+  device #$dev}${RESET} — listen for it..."
  do_locate "$serial" "${LOCATE_BEEPS:-6}"
  echo -e "  ${GREEN}done${RESET} ${DIM}(re-run to beep again)${RESET}"
}

# ---- Push with live progress ----------------------------------------
# Single device: streams adb push output directly to terminal.
# Multiple devices: runs in parallel, polls logfiles every 5s and prints
# a per-device file-count progress line until all jobs finish.
run_push() {
  local src="$1" dest="$2"
  local devices
  devices=$(online_devices)

  if [[ -z "$devices" ]]; then
    echo -e "${RED}No devices online.${RESET}"
    exit 1
  fi

  local count
  count=$(echo "$devices" | wc -l | tr -d ' ')
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  # ---- Single device — stream output live ----------------------------
  if [[ "$count" -eq 1 ]]; then
    local serial
    serial=$(echo "$devices" | head -1)
    echo -e "${CYAN}Pushing to $serial...${RESET}"
    echo ""
    # adb push prints one line per file — stream it directly
    adb -s "$serial" push "$src" "$dest"
    local exit_code=$?
    echo ""
    if [[ $exit_code -eq 0 ]]; then
      echo -e "  ${GREEN}✓${RESET} $serial"
    else
      echo -e "  ${RED}✗${RESET} $serial — push failed (exit $exit_code)"
      return 1
    fi
    return 0
  fi

  # ---- Multiple devices — parallel with polling ----------------------
  echo -e "${CYAN}Pushing to $count device(s) in parallel [max $MAX_PARALLEL]...${RESET}"
  echo ""

  local pids=() serials=() logfiles=()
  local running=0

  while IFS= read -r serial; do
    [[ -z "$serial" ]] && continue
    local logfile="$LOG_DIR/${timestamp}_${serial//:/_}.log"

    while (( running >= MAX_PARALLEL )); do
      running=0
      for p in "${pids[@]}"; do
        kill -0 "$p" 2>/dev/null && ((running++)) || true
      done
      sleep 0.5
    done

    adb -s "$serial" push "$src" "$dest" </dev/null > "$logfile" 2>&1 &
    pids+=($!)
    serials+=("$serial")
    logfiles+=("$logfile")
    ((running++)) || true
  done <<< "$devices"

  # Poll until all done, printing per-device progress every 5s
  local all_done=false
  while ! $all_done; do
    all_done=true
    for i in "${!pids[@]}"; do
      kill -0 "${pids[$i]}" 2>/dev/null && all_done=false || true
    done
    if ! $all_done; then
      echo -ne "\r\033[K"  # clear line
      local summary=""
      for i in "${!pids[@]}"; do
        local serial="${serials[$i]}"
        local logfile="${logfiles[$i]}"
        local ip="${serial%%:*}"
        if kill -0 "${pids[$i]}" 2>/dev/null; then
          # Count files pushed so far (lines containing "]")
          local pushed
          pushed=$(grep -c '\]' "$logfile" 2>/dev/null || echo 0)
          summary+="  ${CYAN}${ip}${RESET}: ${pushed} files"$'\n'
        fi
      done
      echo -ne "${summary}"
      sleep 5
      # Move cursor back up to overwrite progress lines
      local lines
      lines=$(echo "$summary" | wc -l | tr -d ' ')
      echo -ne "\033[${lines}A"
    fi
  done
  echo ""  # leave a clean line after progress

  # Collect results
  local success=0 fail=0
  for i in "${!pids[@]}"; do
    local serial="${serials[$i]}"
    local logfile="${logfiles[$i]}"
    if wait "${pids[$i]}"; then
      # Print the adb push summary line (last line, e.g. "X files pushed. Y MB/s")
      local summary_line
      summary_line=$(tail -1 "$logfile" 2>/dev/null || echo "")
      echo -e "  ${GREEN}✓${RESET} $serial  ${DIM}${summary_line}${RESET}"
      ((success++)) || true
    else
      # Surface the actual failure, not a trailing blank line. The `|| true`
      # guards are required: grep returns non-zero when nothing matches, which
      # under `set -o pipefail` would otherwise abort the whole run right here.
      local why=""
      why=$(grep -iE "Failure|INSTALL_FAILED|adb: |signatures do not match|error" "$logfile" 2>/dev/null | tail -1) || true
      [[ -n "$why" ]] || why=$(grep -v '^[[:space:]]*$' "$logfile" 2>/dev/null | tail -1) || true
      echo -e "  ${RED}✗${RESET} $serial — $why"
      ((fail++)) || true
    fi
  done

  echo ""
  echo -e "Done — Success: ${GREEN}$success${RESET}  Failed: ${RED}$fail${RESET}"
  echo -e "Logs: $LOG_DIR/"
}

# ---- Deploy command — interactive APK selection + asset push --------
cmd_deploy() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   ML2 Deploy — Tin Drum                      ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo -e "${DIM}  $TOOLKIT_VERSION${RESET}"

  show_confirm "install APK(s) to the fleet"

  # ---- Connect devices -----------------------------------------------
  # Always attempt connect first so provisioned devices are reachable.
  # In single-device mode (-d), connect just that IP; otherwise use devices.txt.
  echo -e "${BOLD}── Connecting devices ──────────────────────────────${RESET}"
  echo ""
  if [[ -n "$SINGLE_DEVICE" ]]; then
    local ip="${SINGLE_DEVICE%%:*}"
    if adb connect "${ip}:5555" 2>&1 | grep -q "connected"; then
      echo -e "  ${GREEN}✓${RESET} $ip"
    else
      echo -e "  ${RED}✗${RESET} $ip (failed to connect)"
      exit 1
    fi
  else
    cmd_connect
  fi
  echo ""

  # ---- Find APKs in builds/ ------------------------------------------
  if [[ ! -d "$BUILDS_DIR" ]]; then
    echo -e "${RED}builds/ directory not found at $BUILDS_DIR${RESET}"
    exit 1
  fi

  mapfile -t APKS < <(find "$BUILDS_DIR" -maxdepth 1 -name "*.apk" | sort)

  if [[ ${#APKS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No APKs in builds/ — skipping install.${RESET}"
    echo -e "  To deploy later: ${DIM}./ml_deploy.sh deploy${RESET}"
    return 0
  fi

  # ---- APK selection -------------------------------------------------
  echo -e "${BOLD}APKs available in builds/:${RESET}"
  echo ""
  for i in "${!APKS[@]}"; do
    local size
    size=$(du -sh "${APKS[$i]}" 2>/dev/null | awk '{print $1}')
    echo -e "  [$((i+1))] $(basename "${APKS[$i]}")  ${DIM}(${size})${RESET}"
  done
  echo ""
  echo -e "  Enter numbers separated by spaces to install multiple, e.g. ${DIM}1 2${RESET}"
  echo -e "  Press ${DIM}Enter${RESET} to cancel."
  echo ""
  read -rp "Select APK(s): " APK_SELECTION

  if [[ -z "$APK_SELECTION" ]]; then
    echo "Cancelled."
    exit 0
  fi

  SELECTED_APKS=()
  for idx in $APK_SELECTION; do
    local n=$(( idx - 1 ))
    if [[ $n -lt 0 || $n -ge ${#APKS[@]} ]]; then
      echo -e "${RED}Invalid selection: $idx${RESET}"
      exit 1
    fi
    SELECTED_APKS+=("${APKS[$n]}")
  done

  # ---- Confirm target devices ----------------------------------------
  local device_count
  device_count=$(online_devices | grep -c . || true)

  if [[ "$device_count" -eq 0 ]]; then
    echo -e "${RED}No devices reachable after connect attempt. Check WiFi and try again.${RESET}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}Deploy plan:${RESET}"
  echo ""
  for apk in "${SELECTED_APKS[@]}"; do
    echo -e "  APK:    ${CYAN}$(basename "$apk")${RESET}"
  done
  echo -e "  Target: ${CYAN}$device_count device(s) online${RESET}"
  echo ""
  echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort...${RESET}"
  read -rp ""

  # ---- Install APKs --------------------------------------------------
  for apk in "${SELECTED_APKS[@]}"; do
    echo ""
    echo -e "${BOLD}── Installing $(basename "$apk") ──────────────────────────────${RESET}"
    run_parallel do_install "$apk"
  done

  # ---- Set home app --------------------------------------------------
  echo ""
  echo -e "${BOLD}── Setting home app ──────────────────────────────${RESET}"
  run_parallel do_set_home

  # ---- Reboot (issue #36) --------------------------------------------
  # The show/kiosk SSD asset-transfer scripts are not enabled until the
  # device reboots after an APK install. Let PackageManager flush the
  # home preference to disk first — a bare reboot here races its delayed
  # writer and the device boots to the ML2 home menu instead of the kiosk.
  echo ""
  echo -e "${DIM}  Letting home preference persist before reboot...${RESET}"
  sleep 10
  echo -e "${BOLD}── Rebooting devices ──────────────────────────────${RESET}"
  run_parallel do_reboot

  echo ""
  echo -e "${GREEN}${BOLD}Deploy complete.${RESET} ${DIM}Devices are rebooting.${RESET}"
  echo ""
}

# ---- Non-interactive deploy — installs all APKs in builds/ ----------
# Called by ml_provision.sh at end of provisioning over USB.
# Uses ANDROID_SERIAL env var if set, otherwise falls back to online_devices.
cmd_deploy_all() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   ML2 Deploy — installing all APKs           ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo -e "${DIM}  $TOOLKIT_VERSION${RESET}"

  # No-op when chained from provisioning (already confirmed at flash)
  show_confirm "install all builds/ APKs"
  echo ""

  # If called from ml_provision.sh, ANDROID_SERIAL is set — use it directly
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    online_devices() { echo "$ANDROID_SERIAL"; }
    echo -e "${CYAN}Using USB device: $ANDROID_SERIAL${RESET}"
  fi

  # ---- Find APKs -----------------------------------------------------
  if [[ ! -d "$BUILDS_DIR" ]]; then
    echo -e "${RED}builds/ directory not found at $BUILDS_DIR${RESET}"
    exit 1
  fi

  mapfile -t APKS < <(find "$BUILDS_DIR" -maxdepth 1 -name "*.apk" | sort)

  if [[ ${#APKS[@]} -eq 0 ]]; then
    echo -e "${RED}No APK files found in $BUILDS_DIR${RESET}"
    exit 1
  fi

  echo -e "${BOLD}Installing all APKs in builds/:${RESET}"
  echo ""
  for apk in "${APKS[@]}"; do
    local size
    size=$(du -sh "$apk" 2>/dev/null | awk '{print $1}')
    echo -e "  ${CYAN}$(basename "$apk")${RESET}  ${DIM}(${size})${RESET}"
  done
  echo ""

  # ---- Install -------------------------------------------------------
  for apk in "${APKS[@]}"; do
    echo -e "${BOLD}── Installing $(basename "$apk") ──────────────────────────────${RESET}"
    run_parallel do_install "$apk"
    echo ""
  done

  # ---- Set home app --------------------------------------------------
  echo -e "${BOLD}── Setting home app ──────────────────────────────${RESET}"
  run_parallel do_set_home

  # ---- Reboot (issue #36) --------------------------------------------
  # Asset-transfer scripts aren't enabled until a post-install reboot.
  # Let PackageManager flush the home preference to disk first — a bare
  # reboot here races its delayed writer and the device boots to the ML2
  # home menu instead of the kiosk (the "home not set" regression).
  # Chained from provisioning over USB: wait for the device back so the
  # caller's `adb tcpip 5555` (WiFi ADB enable) still lands.
  echo ""
  echo -e "${DIM}  Letting home preference persist before reboot...${RESET}"
  sleep 10
  echo -e "${BOLD}── Rebooting (enables asset-transfer scripts) ────${RESET}"
  run_parallel do_reboot
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    echo -e "${DIM}  Waiting for device to come back up...${RESET}"
    adb -s "$ANDROID_SERIAL" wait-for-device 2>/dev/null || true
    sleep 20
  fi

  echo ""
  echo -e "${GREEN}${BOLD}APK install complete.${RESET}"
  echo ""
}
SINGLE_DEVICE=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) SINGLE_DEVICE="$2:5555"; shift 2 ;;
    -f) DEVICES_FILE="$2"; shift 2 ;;
    -j) MAX_PARALLEL="$2"; shift 2 ;;
    --all) COMMAND="deploy-all"; shift ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done

COMMAND="${COMMAND:-${1:-help}}"
shift || true

# Override online_devices if single device mode
if [[ -n "$SINGLE_DEVICE" ]]; then
  online_devices() { echo "$SINGLE_DEVICE"; }
fi

# Printing help shouldn't require a configured show
if [[ "$COMMAND" == "help" || "$COMMAND" == "--help" || "$COMMAND" == "-h" ]]; then
  usage
fi

# ---- Resolve active show -------------------------------------------
# shellcheck source=lib/show_config.sh
source "$SCRIPT_DIR/lib/show_config.sh"
# Respect an explicit -f; otherwise use the per-show fleet list
[[ "$DEVICES_FILE" == "$SCRIPT_DIR/devices.txt" ]] && DEVICES_FILE="$SHOW_DEVICES_FILE"

case "$COMMAND" in
  deploy)      cmd_deploy ;;
  deploy-all)  cmd_deploy_all ;;
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
  shutdown)
    echo -e "${YELLOW}Powering off all devices...${RESET}"
    cmd_shutdown
    ;;
  locate)
    cmd_locate "${1:-}"
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
