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

# Homebrew prefix differs by arch: /opt/homebrew (Apple Silicon) vs /usr/local (Intel)
if [[ "$ARCH" == "arm64" ]]; then
  BREW_BIN="/opt/homebrew/bin/brew"
else
  BREW_BIN="/usr/local/bin/brew"
fi

if ! command -v brew &>/dev/null; then
  echo "  Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  printf "  %b  Homebrew installed\n" "$TICK"
else
  printf "  %b  Homebrew already installed\n" "$TICK"
fi

# Put brew (and thus Homebrew bash) on PATH for THIS process — needed in both
# branches: the current shell may predate the .zprofile edit, and the
# "already installed" case never eval'd shellenv at all. Without this, the
# `env bash` shebang on every ml_* script keeps resolving to /bin/bash 3.2.
if [[ -x "$BREW_BIN" ]]; then
  eval "$("$BREW_BIN" shellenv)"
fi

# Persist it so NEW terminals get the right PATH too. Homebrew's own installer
# only edits ~/.zprofile on a fresh install — and .zprofile is read by *login*
# zsh shells only. Operators hit bash 3.2 when their terminal runs a non-login
# interactive shell (reads .zshrc), or uses bash. Append idempotently to every
# profile a macOS shell might read so PATH ordering "just works" regardless.
SHELLENV_LINE="eval \"\$($BREW_BIN shellenv)\""
if [[ -x "$BREW_BIN" ]]; then
  for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    if ! grep -qF "$BREW_BIN shellenv" "$profile" 2>/dev/null; then
      printf '\n# Homebrew on PATH (added by ml_toolkit install.sh)\n%s\n' "$SHELLENV_LINE" >> "$profile"
    fi
  done
  printf "  %b  Added Homebrew to shell profiles (.zprofile/.zshrc/.bash_profile/.bashrc)\n" "$TICK"
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

# bash needs a version-aware check, NOT install_if_missing: `command -v bash`
# always finds macOS's stock /bin/bash 3.2, so the generic helper would report
# "already installed" and never `brew install bash` — the real reason fleet
# laptops stayed on 3.2. Check for the Homebrew bash binary specifically.
BREW_BASH_PATH="$(dirname "$BREW_BIN")/bash"   # e.g. /opt/homebrew/bin/bash
if [[ -x "$BREW_BASH_PATH" ]]; then
  printf "  %b  Homebrew bash already installed\n" "$TICK"
else
  echo "  Installing bash (Homebrew 5+; macOS ships 3.2)..."
  brew install bash
  printf "  %b  bash installed\n" "$TICK"
fi
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
FLEET_KEY_OK=false

# Install the fleet private key as this machine's ADB identity, backing up
# any existing key first. Every operator laptop installs the SAME fleet key,
# so they all present one identity to devices.
install_fleet_key() {
  mkdir -p "$HOME/.android"
  if [[ -f "$ADB_KEY" ]]; then
    cp "$ADB_KEY" "$HOME/.android/adbkey.backup.$(date +%Y%m%d)" 2>/dev/null || true
  fi
  cp "$FLEET_KEY" "$ADB_KEY"
  chmod 600 "$ADB_KEY"
  ssh-keygen -y -f "$ADB_KEY" > "${ADB_KEY}.pub"
  adb kill-server && adb start-server &>/dev/null || true
}

# True if ~/.android/adbkey already matches the fleet key.
fleet_key_matches() {
  [[ -f "$ADB_KEY" && -f "$FLEET_KEY" ]] || return 1
  local cur fleet
  cur=$(ssh-keygen -y -f "$ADB_KEY" 2>/dev/null | awk '{print $2}' || echo "")
  fleet=$(ssh-keygen -y -f "$FLEET_KEY" 2>/dev/null | awk '{print $2}' || echo "")
  [[ -n "$fleet" && "$cur" == "$fleet" ]]
}

if fleet_key_matches; then
  printf "  %b  ADB fleet key already configured\n" "$TICK"
  FLEET_KEY_OK=true
elif [[ -f "$FLEET_KEY" ]]; then
  echo -e "  ${YELLOW}Installing fleet key (your current key will be backed up).${RESET}"
  install_fleet_key
  printf "  %b  Fleet ADB key installed\n" "$TICK"
  FLEET_KEY_OK=true
else
  # The fleet key is distributed separately and is gitignored, so a fresh
  # clone never has it. Prompt the operator to drop it in now and wait. We
  # read from /dev/tty (not stdin) so this works even under `curl ... | bash`,
  # where stdin is the piped script rather than the keyboard.
  echo -e "  ${YELLOW}${BOLD}Fleet ADB key needed.${RESET}"
  echo -e "  Get the file ${CYAN}adbkey_kagami_fleet${RESET} from your team lead"
  echo -e "  (AirDrop, 1Password, etc.) and copy it into the folder created here:"
  echo -e "     ${CYAN}$INSTALL_DIR/authorized_keys/${RESET}"
  echo -e "  ${DIM}full path: $FLEET_KEY${RESET}"
  echo ""

  if [[ -r /dev/tty ]]; then
    while true; do
      printf "  Press ${BOLD}Enter${RESET} once the file is in place, or type ${BOLD}s${RESET} to skip: "
      IFS= read -r reply < /dev/tty || reply="s"
      if [[ "$reply" == "s" || "$reply" == "S" ]]; then
        break
      fi
      if [[ -f "$FLEET_KEY" ]]; then
        install_fleet_key
        printf "  %b  Fleet ADB key installed\n" "$TICK"
        FLEET_KEY_OK=true
        break
      fi
      echo -e "  ${YELLOW}Still not found at that path — check the filename (no extension) and try again.${RESET}"
    done
  fi

  if [[ "$FLEET_KEY_OK" != true ]]; then
    echo ""
    echo -e "  ${YELLOW}Fleet key not installed yet.${RESET} Once you have it, place it at the"
    echo -e "  path above and run ${CYAN}cd $INSTALL_DIR && ./install.sh${RESET} again to finish."
    echo -e "  ${DIM}Without this key, every device needs a manual 'Allow USB debugging'"
    echo -e "  tap before this laptop can connect.${RESET}"
  fi
fi

# ---- Verify shell is using Homebrew bash ---------------------------
echo ""
echo -e "${BOLD}Verifying shell configuration...${RESET}"
echo ""

# The ml_* scripts use a `#!/usr/bin/env bash` shebang, so they run whatever
# `bash` PATH resolves first. That MUST be Homebrew bash 5+ — macOS's stock
# /bin/bash is 3.2 and lacks `mapfile` et al.
#
# Verify what a FRESH shell will resolve, NOT this process: install.sh already
# eval'd `brew shellenv` above, so its own PATH always finds bash 5 and would
# falsely report success even when the operator's terminals still get 3.2.
# Spawn a clean login+interactive shell so the probe reflects the profiles we
# just wrote — i.e. what `bash --version` will say in a new terminal.
# single quotes intentional: BASH_VERSINFO must expand in the child bash
# shellcheck disable=SC2016
PROBE='b=$(command -v bash); echo "$b ${BASH_VERSINFO:-}"; "$b" -c "echo \${BASH_VERSINFO[0]}"'
FRESH=$(zsh -lic "$PROBE" 2>/dev/null | tail -1 || echo 0)
RESOLVED_BASH=$(zsh -lic 'command -v bash' 2>/dev/null | tail -1 || true)

if [[ "${FRESH:-0}" -ge 5 ]]; then
  printf "  %b  new terminals will use bash %s.x (%s)\n" "$TICK" "$FRESH" "$RESOLVED_BASH"
else
  printf "  %b  ${YELLOW}a new terminal would still resolve bash to %s.x (%s)${RESET}\n" \
    "$CROSS" "${FRESH:-?}" "${RESOLVED_BASH:-not found}"
  echo -e "     ${YELLOW}The profile edit didn't take for your login shell.${RESET}"
  echo -e "     Run this in the terminal you'll use, then re-check ${CYAN}bash --version${RESET}:"
  echo -e "       ${CYAN}eval \"\$($BREW_BIN shellenv)\"${RESET}"
fi

# ---- Final summary -------------------------------------------------
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
if [[ "$FLEET_KEY_OK" == true ]]; then
  echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
else
  echo -e "${YELLOW}${BOLD}Installation finished — fleet key still needed.${RESET}"
  echo -e "  ${DIM}Re-run ./install.sh after placing adbkey_kagami_fleet to finish.${RESET}"
fi
echo ""
echo -e "  Toolkit location: ${CYAN}$INSTALL_DIR${RESET}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
if [[ "$FLEET_KEY_OK" != true ]]; then
  echo -e "  ${YELLOW}${BOLD}First — finish the fleet key (required before this laptop can reach devices):${RESET}"
  echo -e "     a. Get ${CYAN}adbkey_kagami_fleet${RESET} from your team lead (AirDrop, 1Password, etc.)"
  echo -e "     b. Copy it into ${CYAN}$INSTALL_DIR/authorized_keys/${RESET}"
  echo -e "     c. Re-run ${CYAN}cd $INSTALL_DIR && ./install.sh${RESET}"
  echo -e "        ${DIM}— it activates the key and then reports \"Installation complete!\"${RESET}"
  echo ""
fi
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
