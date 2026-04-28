#!/usr/bin/env bash
# ============================================================
# KAGAMI Fleet Toolkit — Install Script
# Tin Drum / Magic Leap 2 Fleet Management
#
# Usage (after cloning the repo):
#   chmod +x install.sh && ./install.sh
#
# Or one-liner from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/uurf/ml_fleet_tools/main/install.sh | bash
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
TICK="${GREEN}✓${RESET}"; CROSS="${RED}✗${RESET}"

REPO_URL="https://github.com/uurf/ml_fleet_tools.git"
INSTALL_DIR="$HOME/Developer/ml_toolkit"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   KAGAMI Fleet Toolkit — Installer           ║${RESET}"
echo -e "${BOLD}║   Tin Drum                                    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""

# ---- Check platform ------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
  echo -e "${RED}This toolkit is designed for macOS only.${RESET}"
  exit 1
fi

ARCH=$(uname -m)
echo -e "  Platform: ${CYAN}macOS ($ARCH)${RESET}"
echo ""

# ---- Check/install Homebrew ----------------------------------------
echo -e "${BOLD}Checking dependencies...${RESET}"
echo ""

if ! command -v brew &>/dev/null; then
  echo "  Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon
  if [[ "$ARCH" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  printf "  %b  Homebrew installed\n" "$TICK"
else
  printf "  %b  Homebrew already installed\n" "$TICK"
fi

# ---- Install required packages -------------------------------------
install_if_missing() {
  local pkg="$1" cmd="${2:-$1}"
  if ! command -v "$cmd" &>/dev/null; then
    echo "  Installing $pkg..."
    brew install "$pkg"
    printf "  %b  %s installed\n" "$TICK" "$pkg"
  else
    printf "  %b  %s already installed\n" "$TICK" "$pkg"
  fi
}

install_if_missing "android-platform-tools" "adb"
install_if_missing "bash"
install_if_missing "git"
install_if_missing "python3"

echo ""

# ---- Clone or update repo ------------------------------------------
echo -e "${BOLD}Setting up toolkit...${RESET}"
echo ""

if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "  Updating existing installation at $INSTALL_DIR..."
  git -C "$INSTALL_DIR" pull --ff-only
  printf "  %b  Toolkit updated\n" "$TICK"
elif [[ -d "$INSTALL_DIR" ]]; then
  echo -e "  ${YELLOW}Directory exists but is not a git repo: $INSTALL_DIR${RESET}"
  echo "  Please remove or rename it and re-run install.sh"
  exit 1
else
  echo "  Cloning toolkit to $INSTALL_DIR..."
  mkdir -p "$HOME/Developer"
  git clone "$REPO_URL" "$INSTALL_DIR"
  printf "  %b  Toolkit cloned\n" "$TICK"
fi

# ---- Make scripts executable ---------------------------------------
chmod +x "$INSTALL_DIR"/*.sh
printf "  %b  Scripts made executable\n" "$TICK"

# ---- Create required directories -----------------------------------
mkdir -p "$INSTALL_DIR/os_images"
mkdir -p "$INSTALL_DIR/builds"
mkdir -p "$INSTALL_DIR/builds/assets"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/status"
printf "  %b  Directories created\n" "$TICK"

# ---- Set up ADB fleet key ------------------------------------------
echo ""
echo -e "${BOLD}Setting up ADB fleet key...${RESET}"
echo ""

FLEET_KEY="$INSTALL_DIR/authorized_keys/adbkey_kagami_fleet"
ADB_KEY="$HOME/.android/adbkey"

if [[ -f "$FLEET_KEY" ]]; then
  # Check if current adb key matches fleet key
  if [[ -f "$ADB_KEY" ]]; then
    CURRENT_PUB=$(ssh-keygen -y -f "$ADB_KEY" 2>/dev/null | awk '{print $2}' || echo "")
    FLEET_PUB=$(ssh-keygen -y -f "$FLEET_KEY" 2>/dev/null | awk '{print $2}' || echo "")
    if [[ "$CURRENT_PUB" == "$FLEET_PUB" ]]; then
      printf "  %b  ADB fleet key already configured\n" "$TICK"
    else
      echo -e "  ${YELLOW}Installing fleet key (your current key will be backed up).${RESET}"
      cp "$ADB_KEY" "$HOME/.android/adbkey.backup.$(date +%Y%m%d)" 2>/dev/null || true
      cp "$FLEET_KEY" "$ADB_KEY"
      chmod 600 "$ADB_KEY"
      ssh-keygen -y -f "$ADB_KEY" > "${ADB_KEY}.pub"
      adb kill-server && adb start-server &>/dev/null || true
      printf "  %b  Fleet ADB key installed\n" "$TICK"
    fi
  else
    mkdir -p "$HOME/.android"
    cp "$FLEET_KEY" "$ADB_KEY"
    chmod 600 "$ADB_KEY"
    ssh-keygen -y -f "$ADB_KEY" > "${ADB_KEY}.pub"
    adb kill-server && adb start-server &>/dev/null || true
    printf "  %b  Fleet ADB key installed\n" "$TICK"
  fi
else
  printf "  %b  ${YELLOW}Fleet ADB key not found${RESET}\n" "$CROSS"
  echo ""
  echo -e "  ${YELLOW}${BOLD}Action required:${RESET}"
  echo -e "  The fleet ADB key is distributed separately for security."
  echo -e "  Ask your team lead for the file: ${CYAN}adbkey${RESET}"
  echo -e "  Then place it at: ${CYAN}$FLEET_KEY${RESET}"
  echo -e "  And run: ${CYAN}./install.sh${RESET} again"
  echo ""
  echo -e "  ${DIM}Without this key, devices flashed on other machines will require"
  echo -e "  a one-time 'Allow USB debugging' tap per laptop.${RESET}"
fi

# ---- Verify shell is using Homebrew bash ---------------------------
echo ""
echo -e "${BOLD}Verifying shell configuration...${RESET}"
echo ""

BREW_BASH="/opt/homebrew/bin/bash"
if [[ -f "$BREW_BASH" ]]; then
  # Scripts already use Homebrew bash shebang — no modification needed
  printf "  %b  Homebrew bash available at %s\n" "$TICK" "$BREW_BASH"
else
  printf "  %b  ${YELLOW}Homebrew bash not found — scripts may fail on Apple Silicon${RESET}\n" "$CROSS"
fi

# ---- Final summary -------------------------------------------------
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
echo ""
echo -e "  Toolkit location: ${CYAN}$INSTALL_DIR${RESET}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo "  1. Download OS image from ML Hub:"
echo "     Package Manager → Device OS Versions → 1.4.1 → Apply"
echo "     Then copy the image folder to:"
echo -e "     ${CYAN}$INSTALL_DIR/os_images/${RESET}"
echo ""
echo "  2. Start provisioning:"
echo -e "     ${CYAN}cd $INSTALL_DIR${RESET}"
echo -e "     ${CYAN}./ml_os_flash.sh ./os_images B3E.230928.10-R.098${RESET}"
echo ""
echo "  See SETUP.md and PROVISIONING.md for full instructions."
echo ""
