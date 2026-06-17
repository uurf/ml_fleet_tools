# shellcheck shell=bash
# ============================================================
# require_bash5.sh — hard-stop if not running under bash 5+
#
# Sourced as the first thing every ml_* script does. macOS ships
# bash 3.2, which lacks `mapfile`, associative arrays, etc. The
# scripts use a `#!/usr/bin/env bash` shebang, so they silently
# run under 3.2 whenever Homebrew bash isn't first on PATH (e.g.
# a terminal opened before install.sh edited ~/.zprofile, or a
# `sh script.sh` / `/bin/bash script.sh` invocation). Without this
# guard the failure surfaces deep inside a script as a cryptic
# `mapfile: command not found`. Fail early and explain instead.
#
# This file MUST stay bash-3.2-compatible — it runs BEFORE we know
# the version. No mapfile, no associative arrays, no `${x^^}`, etc.
# ============================================================

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  _rb_ver="${BASH_VERSION:-unknown}"
  # $BASH is the actual running interpreter; fall back to a PATH lookup
  _rb_bash="${BASH:-$(command -v bash 2>/dev/null || echo bash)}"
  printf '\033[0;31m✗  This script needs bash 5+, but it is running under bash %s\033[0m\n' "$_rb_ver" >&2
  printf '   Interpreter: %s\n' "$_rb_bash" >&2
  printf '\n' >&2
  printf '   Fix:\n' >&2
  printf '     1. Open a NEW terminal (picks up Homebrew on PATH), OR run: \033[0;36mexec zsh -l\033[0m\n' >&2
  printf '     2. Launch the script directly: \033[0;36m./%s\033[0m  — not  \033[2msh %s\033[0m or \033[2m/bin/bash %s\033[0m\n' \
    "$(basename "${BASH_SOURCE[1]:-this script}")" "$(basename "${BASH_SOURCE[1]:-script}")" "$(basename "${BASH_SOURCE[1]:-script}")" >&2
  printf '\n' >&2
  printf '   If a new terminal still shows bash 3.2, re-run \033[0;36m./install.sh\033[0m.\n' >&2
  exit 1
fi
