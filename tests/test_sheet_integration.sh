#!/usr/bin/env bash
# ============================================================
# tests/test_sheet_integration.sh
#
# Device-free regression tests for the per-show Google Sheets
# integration (SHOW_SHEETS_URL in shows/<id>.conf, consumed by
# update_sheet() in ml_provision.sh / ml_os_flash.sh).
#
# Run from anywhere:
#   ./tests/test_sheet_integration.sh
#
# What it covers:
#   T1: lib/show_config.sh exports SHOW_SHEETS_URL for KAGAMI
#       (matches the live deployment URL in shows/KAGAMI.conf).
#   T2: a conf without SHOW_SHEETS_URL defaults SHOW_SHEETS_URL=""
#       (no hard-stop — the field is optional).
#   T3: required-field validation still hard-stops if SHOW_SSID
#       is missing (regression — make sure the new optional field
#       didn't accidentally land in the required-fields list).
#   T4: update_sheet (ml_provision.sh) early-returns when
#       SHOW_SHEETS_URL is empty — no python3 invocation.
#   T5: update_sheet (ml_provision.sh) interpolates SHOW_SHEETS_URL
#       into the Python heredoc verbatim — no stale URL leakage.
#   T6: T4 for ml_os_flash.sh.
#   T7: T5 for ml_os_flash.sh.
#   T8: ml_show.sh init writes a SHOW_SHEETS_URL= line into the
#       generated conf, populated with the operator's answer.
#   T9: apps_script/Code.gs has SHEET_TAB_NAME at the top and
#       getSheetByName uses it (no hardcoded tab name left).
# ============================================================

set -u  # not -e — we want every test to run, even after a failure

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Per-test functions run inside subshells (for env/PATH isolation).
# Counters are incremented via append-only tally files so the parent
# can read the totals; can't use plain bash vars across subshells.
TALLY_DIR=$(mktemp -d)
trap 'rm -rf "$TALLY_DIR"' EXIT
export TALLY_DIR

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

pass() { printf "P\n" >> "$TALLY_DIR/results"; printf "  ${GREEN}PASS${RESET}  %s\n" "$*"; }
fail() { printf "F\n" >> "$TALLY_DIR/results"; printf "  ${RED}FAIL${RESET}  %s\n" "$*"; }
export -f pass fail

# Pull a function body out of a script — used so we can call
# update_sheet in this test process without running the full script
# (which would trigger update gate, show resolution, adb, etc.).
extract_function() {
  local script="$1" fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn=1 }
    in_fn { print }
    in_fn && /^\}$/ { exit }
  ' "$script"
}

# Drop a fake python3 on PATH that records its invocation
# (args + the `-c` code body) to $PY_CAPTURE instead of running it.
install_fake_python() {
  local dir="$1"
  cat > "$dir/python3" <<'EOF'
#!/usr/bin/env bash
{
  echo "INVOKED"
  echo "ARGS: $*"
  if [[ "${1:-}" == "-c" ]]; then
    echo "---CODE-START---"
    printf '%s\n' "$2"
    echo "---CODE-END---"
  fi
} >> "${PY_CAPTURE:?PY_CAPTURE not set}"
exit 0
EOF
  chmod +x "$dir/python3"
}

printf "\n${BOLD}== per-show sheet integration tests ==${RESET}\n"
printf "${DIM}  repo: %s${RESET}\n\n" "$REPO"

# ------------------------------------------------------------
# T1: show_config exports SHOW_SHEETS_URL for KAGAMI
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/lib" "$TMP/shows"
  cp "$REPO/lib/show_config.sh" "$TMP/lib/"
  cp "$REPO/shows/KAGAMI.conf"  "$TMP/shows/"
  expected=$(grep -E '^SHOW_SHEETS_URL=' "$REPO/shows/KAGAMI.conf" | sed -E 's/^SHOW_SHEETS_URL="(.*)"$/\1/')
  result=$(ML_SHOW=KAGAMI ML_SHOW_CONFIRMED=1 \
           bash -c "source '$TMP/lib/show_config.sh'; echo \"\$SHOW_SHEETS_URL\"" 2>/dev/null)
  if [[ "$result" == "$expected" && -n "$result" ]]; then
    pass "T1 KAGAMI exports SHOW_SHEETS_URL = ${result:0:60}…"
  else
    fail "T1 KAGAMI SHOW_SHEETS_URL mismatch (got '$result', want '$expected')"
  fi
)

# ------------------------------------------------------------
# T2: a conf without SHOW_SHEETS_URL → empty default, no error
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/lib" "$TMP/shows"
  cp "$REPO/lib/show_config.sh" "$TMP/lib/"
  cat > "$TMP/shows/TESTSHOW.conf" <<'EOF'
SHOW_NAME="TestShow"
SHOW_SSID="test"
SHOW_WIFI_PASSWORD="testpass"
SHOW_WIFI_SECURITY="wpa2"
SHOW_PACKAGE="com.tindrum.test"
SHOW_BRIGHTNESS="12"
SHOW_DATA_DIR="Test"
SHOW_DISK_WARN_PCT="60"
# (deliberately NO SHOW_SHEETS_URL line)
EOF
  output=$(ML_SHOW=TESTSHOW ML_SHOW_CONFIRMED=1 \
           bash -c "source '$TMP/lib/show_config.sh' && echo \"URL=[\$SHOW_SHEETS_URL]\"" 2>&1)
  if [[ "$output" == *"URL=[]"* ]]; then
    pass "T2 missing SHOW_SHEETS_URL → empty default (no hard-stop)"
  else
    fail "T2 unexpected output: $output"
  fi
)

# ------------------------------------------------------------
# T3: required-field validation still fires
#     (regression guard — SHOW_SHEETS_URL must NOT be required)
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/lib" "$TMP/shows"
  cp "$REPO/lib/show_config.sh" "$TMP/lib/"
  cat > "$TMP/shows/BROKEN.conf" <<'EOF'
SHOW_NAME="Broken"
# SHOW_SSID intentionally missing
SHOW_WIFI_PASSWORD="x"
SHOW_WIFI_SECURITY="wpa2"
SHOW_PACKAGE="com.x.y"
SHOW_BRIGHTNESS="12"
SHOW_DATA_DIR="X"
SHOW_DISK_WARN_PCT="60"
EOF
  output=$(ML_SHOW=BROKEN ML_SHOW_CONFIRMED=1 \
           bash -c "source '$TMP/lib/show_config.sh' && echo SHOULD_NOT_GET_HERE" 2>&1 || true)
  if [[ "$output" == *"SHOULD_NOT_GET_HERE"* ]]; then
    fail "T3 resolver let a missing SHOW_SSID through"
  elif [[ "$output" == *"missing required field"*"SHOW_SSID"* ]]; then
    pass "T3 missing SHOW_SSID still hard-stops"
  else
    fail "T3 unexpected output: $output"
  fi
)

# ------------------------------------------------------------
# T4: ml_provision.sh update_sheet — empty URL → no python3 call
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  install_fake_python "$TMP"
  export PATH="$TMP:$PATH" PY_CAPTURE="$TMP/capture.log"
  : > "$PY_CAPTURE"

  body=$(extract_function "$REPO/ml_provision.sh" update_sheet)
  # shellcheck disable=SC2034
  SHOW_SHEETS_URL=""
  eval "$body"
  update_sheet provision_start ABC123 "" "" "false" "JD"

  if [[ -s "$PY_CAPTURE" ]]; then
    fail "T4 ml_provision update_sheet invoked python3 with empty URL"
    sed 's/^/      /' "$PY_CAPTURE" | head -8
  else
    pass "T4 ml_provision update_sheet no-ops when SHOW_SHEETS_URL=''"
  fi
)

# ------------------------------------------------------------
# T5: ml_provision.sh update_sheet — interpolates URL verbatim
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  install_fake_python "$TMP"
  export PATH="$TMP:$PATH" PY_CAPTURE="$TMP/capture.log"
  : > "$PY_CAPTURE"

  body=$(extract_function "$REPO/ml_provision.sh" update_sheet)
  SHOW_SHEETS_URL="https://example.test/macros/s/UNIQUE_PROVISION_MARKER/exec"
  eval "$body"
  update_sheet provision_start ABC123 "" "" "false" "JD"

  if grep -q "UNIQUE_PROVISION_MARKER" "$PY_CAPTURE" 2>/dev/null; then
    pass "T5 ml_provision update_sheet posted to configured URL"
  else
    fail "T5 ml_provision update_sheet didn't use SHOW_SHEETS_URL"
    sed 's/^/      /' "$PY_CAPTURE" | head -12
  fi

  if grep -q "AKfycb" "$PY_CAPTURE" 2>/dev/null; then
    fail "T5b ml_provision still leaks an old hardcoded AKfycb… URL"
  else
    pass "T5b ml_provision no stale AKfycb… URL in heredoc"
  fi
)

# ------------------------------------------------------------
# T6: ml_os_flash.sh update_sheet — empty URL → no python3 call
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  install_fake_python "$TMP"
  export PATH="$TMP:$PATH" PY_CAPTURE="$TMP/capture.log"
  : > "$PY_CAPTURE"

  body=$(extract_function "$REPO/ml_os_flash.sh" update_sheet)
  SHOW_SHEETS_URL=""
  eval "$body"
  update_sheet flash_start ABC123 "" "" "JD"

  if [[ -s "$PY_CAPTURE" ]]; then
    fail "T6 ml_os_flash update_sheet invoked python3 with empty URL"
  else
    pass "T6 ml_os_flash update_sheet no-ops when SHOW_SHEETS_URL=''"
  fi
)

# ------------------------------------------------------------
# T7: ml_os_flash.sh update_sheet — interpolates URL verbatim
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  install_fake_python "$TMP"
  export PATH="$TMP:$PATH" PY_CAPTURE="$TMP/capture.log"
  : > "$PY_CAPTURE"

  body=$(extract_function "$REPO/ml_os_flash.sh" update_sheet)
  SHOW_SHEETS_URL="https://example.test/macros/s/UNIQUE_FLASH_MARKER/exec"
  eval "$body"
  update_sheet flash_start ABC123 "" "" "JD"

  if grep -q "UNIQUE_FLASH_MARKER" "$PY_CAPTURE" 2>/dev/null; then
    pass "T7 ml_os_flash update_sheet posted to configured URL"
  else
    fail "T7 ml_os_flash update_sheet didn't use SHOW_SHEETS_URL"
    sed 's/^/      /' "$PY_CAPTURE" | head -12
  fi

  if grep -q "AKfycb" "$PY_CAPTURE" 2>/dev/null; then
    fail "T7b ml_os_flash still leaks an old hardcoded AKfycb… URL"
  else
    pass "T7b ml_os_flash no stale AKfycb… URL in heredoc"
  fi
)

# ------------------------------------------------------------
# T8: ml_show.sh init writes SHOW_SHEETS_URL into shows/<id>.conf
# ------------------------------------------------------------
(
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  cp "$REPO/ml_show.sh" "$TMP/"
  mkdir -p "$TMP/shows"
  # Drive ml_show.sh init non-interactively. Order must match the
  # prompts in cmd_init:
  #   id, name, ssid, password, security, package, brightness,
  #   data_dir, data_required, data_optional, disk_pct,
  #   expected_apk, expected_os, sheets_url, make_active
  cd "$TMP"
  printf 'TESTSHOW\nTest Show\nTEST_SSID\ntestpw\nwpa2\ncom.tindrum.test\n12\nTest\ndata\napplogs\n60\n\n\nhttps://test.example/macros/s/UNIQUE_INIT_MARKER/exec\nn\n' \
    | bash ml_show.sh init >/dev/null 2>&1
  conf="$TMP/shows/TESTSHOW.conf"
  if [[ ! -f "$conf" ]]; then
    fail "T8 ml_show.sh init didn't write shows/TESTSHOW.conf"
  elif grep -q 'SHOW_SHEETS_URL="https://test.example/macros/s/UNIQUE_INIT_MARKER/exec"' "$conf"; then
    pass "T8 ml_show.sh init wrote SHOW_SHEETS_URL into the conf"
  else
    fail "T8 ml_show.sh init didn't write the expected SHOW_SHEETS_URL line"
    echo "    --- generated conf ---"
    sed 's/^/      /' "$conf"
  fi
)

# ------------------------------------------------------------
# T9: apps_script/Code.gs uses SHEET_TAB_NAME (no hardcoded tab)
# ------------------------------------------------------------
(
  gs="$REPO/apps_script/Code.gs"
  if grep -qE '^const SHEET_TAB_NAME = "[^"]+";' "$gs" && \
     grep -q '\.getSheetByName(SHEET_TAB_NAME)' "$gs" && \
     ! grep -q 'getSheetByName("Kagami' "$gs"; then
    pass "T9 Code.gs is parameterized — SHEET_TAB_NAME const used in getSheetByName()"
  else
    fail "T9 Code.gs missing SHEET_TAB_NAME wiring or still has a hardcoded tab string"
  fi
)

PASS=$(grep -c '^P' "$TALLY_DIR/results" 2>/dev/null || true)
FAIL=$(grep -c '^F' "$TALLY_DIR/results" 2>/dev/null || true)
PASS=${PASS:-0}; FAIL=${FAIL:-0}
printf "\n${BOLD}== %d pass / %d fail ==${RESET}\n\n" "$PASS" "$FAIL"
exit "$FAIL"
