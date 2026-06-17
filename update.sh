#!/usr/bin/env bash
# ============================================================
# ML Fleet Toolkit — Update Script
# Run this to get the latest version of all scripts.
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"

# NOTE: do NOT add the bash-5 guard here. update.sh only runs git + the fleet-key
# backup, none of which need bash 5 — and gating it would deadlock the exact
# bash-3.2 machines that need to pull the fix (the v1.1.3 regression). install.sh
# (also guard-free, 3.2-safe) is what puts Homebrew bash on PATH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${BOLD}ML Fleet Toolkit — Update${RESET}"
echo ""

cd "$SCRIPT_DIR"

# Protect the fleet key if present
KEY_FILE="$SCRIPT_DIR/authorized_keys/adbkey_kagami_fleet"
KEY_BACKUP="/tmp/adbkey_kagami_fleet_backup"
if [[ -f "$KEY_FILE" ]]; then
  cp "$KEY_FILE" "$KEY_BACKUP"
fi

# Discard any local modifications and pull latest
git fetch origin
git reset --hard origin/main

# Restore the fleet key
if [[ -f "$KEY_BACKUP" ]]; then
  cp "$KEY_BACKUP" "$KEY_FILE"
  rm "$KEY_BACKUP"
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR"/*.sh

printf "  %b  Updated to latest version\n" "$TICK"

# Show what changed
echo ""
echo -e "${DIM}Recent changes:${RESET}"
git log --oneline -5
echo ""
echo -e "  Run ${CYAN}./install.sh${RESET} if you need to reconfigure your environment."
echo ""
