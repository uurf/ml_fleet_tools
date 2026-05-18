# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ml_toolkit** is a zero-MDM fleet management system for Magic Leap 2 (ML2) XR headsets, built for the KAGAMI show (Tin Drum). It handles the complete device lifecycle over ADB: OS flashing via fastboot, device provisioning, APK/asset deployment, and fleet monitoring over WiFi ADB.

The toolkit supports **multiple shows from one codebase** (e.g. KAGAMI and a second concurrent show). Show-specific values — WiFi, show-app package, expected versions — live in per-show config (`shows/<id>.conf`), not hardcoded. See **Multi-Show Configuration** below.

**Target OS**: ML2 1.4.1 (Build B3E.230928.10-R.098) — shared across shows  
**Kiosk/Home App**: com.tindrum.kiosk — shared across shows  
**ADB Port**: 5555 (WiFi) — shared across shows  
**Per-show** (from `shows/<id>.conf`): WiFi SSID/password/security, show-app package, expected APK/OS. Default show `KAGAMI` mirrors the original hardcoded values.

## Running Scripts

There is no build system. All scripts are standalone bash and run directly:

```bash
./install.sh                        # First-time machine setup (macOS only, Homebrew)
./update.sh                         # Pull latest from main, protect fleet key
./ml_show.sh [use <id>|init]        # Select/create the active show (on-site setup for show 2)
./ml_os_flash.sh [version] [path]              # Flash OS, pre-auth ADB, skip OOBE, chain to provision
./ml_provision.sh [-d <ip>] [--check|--discover]  # Single-device: apply settings, WiFi, permissions
./ml_provision.sh --fleet [--check]            # Fleet: apply/check ADB-settable settings on the active show's devices
./ml_deploy.sh <command> [options]             # Fleet APK install, asset push, app management
./ml_status.sh [--json|--csv|--failures|--fix] # Parallel status collection
./utilities/ml_scan.sh [--subnet] [--append]   # Scan network for ML2 devices, write devices/<show>.txt
./utilities/ml_ssd_copy.sh                     # Copy show assets from USB-C SSD to fleet
```

**Shell requirement**: Scripts require bash 5+ (macOS ships with bash 3.2; Homebrew bash is required). `install.sh` handles this.

**Linting/testing**: There is no test suite. Manual testing is done against real devices. Use `shellcheck` if available for static analysis of shell scripts.

## Architecture

### Script Pipeline (in order)

```
ml_os_flash.sh → ml_provision.sh → ml_deploy.sh → ml_ssd_copy.sh → ml_status.sh
```

Each script in the chain auto-runs the next when successful. They communicate via environment variables: `ANDROID_SERIAL`, `DEVICE_NUMBER`, `CASE_NUMBER`, `OPERATOR_INITIALS`, `CHAIN_DEPLOY`, `ML_SHOW`, `ML_SHOW_CONFIRMED`. `ML_SHOW` carries the active show down the chain; `ML_SHOW_CONFIRMED=1` is exported after the operator types the show id at the flash gate so downstream scripts don't re-prompt.

### Update Gate

Every main script (flash, provision, deploy, status) fetches `origin/main` at startup and **hard-stops if the local HEAD differs**. This ensures all operators run the same version. The check is bypassed when a script is called by another script (detected via env var like `ANDROID_SERIAL`).

### Multi-Show Configuration

The toolkit runs multiple shows (e.g. two concurrent ~200-device fleets) from one codebase. `lib/show_config.sh` is sourced by every main script and resolves the active show:

1. `$ML_SHOW` (set by the chain, or by an operator's env) →
2. `.active_show` file (gitignored; set once per machine via `./ml_show.sh use <id>`) →
3. hard-stop with instructions if neither is set.

It sources `shows/<id>.conf` (committed; defines `SHOW_SSID`, `SHOW_WIFI_PASSWORD`, `SHOW_WIFI_SECURITY`, `SHOW_PACKAGE`, optional `SHOW_EXPECTED_APK`/`SHOW_EXPECTED_OS`/`SHOW_NAME`), validates required fields, and exports `SHOW_*` plus `SHOW_DEVICES_FILE`. Scripts assign their previously-hardcoded vars from `SHOW_*` (e.g. `ml_provision.sh`'s `WIFI_SSID="$SHOW_SSID"`). `shows/KAGAMI.conf` reproduces the original hardcoded values byte-for-byte, so the KAGAMI show's behavior is unchanged.

**Per-show devices file**: `devices/<id>.txt` (gitignored) is the canonical fleet list (`ml_scan.sh`/`ml_show.sh` write it). Reads fall back to legacy `devices.txt` if the per-show file doesn't exist yet, so the live fleet keeps working pre-migration. An explicit `-f <file>` still overrides.

**Confirmation**: destructive entry points (flash, provision, deploy) call `show_confirm`, which prints the resolved show and requires the operator to type the show id. It is a silent no-op when `ML_SHOW_CONFIRMED=1` is inherited from a parent in the chain (so the operator confirms once, at flash). Read-only paths (`ml_status.sh`, `--check`) only print `show_banner` — and in `ml_status.sh` the banner goes to **stderr** so `--json`/`--csv` stdout stays machine-readable.

**On-site setup for a new show**: `./ml_show.sh init` prompts for the values, writes `shows/<id>.conf`, and offers to make it active — no hand-editing of bash on site.

### ADB Pre-Authorization

On first boot after flash, `ml_os_flash.sh` injects all known public keys from `authorized_keys/` into `/data/misc/adb/adb_keys` on the device, then restarts `adbd`. This permanently suppresses the "Allow USB debugging?" dialog for all authorized machines.

**Fleet key**: `authorized_keys/adbkey_kagami_fleet` is the shared private ADB key (gitignored, distributed separately). Every operator machine installs this to `~/.android/adbkey` via `install.sh`. `update.sh` backs it up before `git reset --hard` and restores it after.

### Parallel Execution Pattern

`ml_deploy.sh`, `ml_status.sh`, and `ml_ssd_copy.sh` use the same background-job throttling pattern:
- Spawn jobs with `&`, track PIDs
- Poll with `sleep 0.1` until a slot frees
- Collect exit codes, log per-device output to `logs/[timestamp]_[ip].log`
- Default job limits: 20 (deploy), 30 (status), 8 (ssd_copy)

### Google Sheets Integration

`ml_os_flash.sh` and `ml_provision.sh` POST JSON to a Google Apps Script web app at each pipeline phase (flash_start, flash_complete, flash_failed, provision_start, provision_complete, deploy_complete). The call is made via Python's `urllib` (no extra dependencies). The Apps Script code is in `apps_script/Code.gs` and looks up columns by header text (survives column reordering).

### macOS Compatibility Patches

`ml_os_flash.sh` patches ML's official `flashall_amd.sh` in-place before running it:
- `stat -c%s` → `stat -f%z` (BSD stat syntax)
- Removes `lsusb` calls (not on macOS)
- Replaces bundled `Darwin/adb` and `Darwin/fastboot` binaries with Homebrew versions (ARM-native)
- Disables `usbrecovery_host` check

### Known Flash Behavior

The `ecfw` partition fails harmlessly during a downgrade flash — this is expected and handled with `continue`. Failures on `kernel` or `system` partitions are fatal and trigger a `flash_failed` sheet update.

### Manual-Only Settings

Some ML2 settings cannot be configured via ADB on the user build and require manual headset UI taps:
- Display Override, Segmented Dimming, Global/Max Dimming levels
- Compute Pack Standby → Off
- OS Updater → Never

`ml_provision.sh` prints a checklist for these after auto-config completes. `--check` mode verifies which are still missing.

### ADB-Settable Settings (applied by `ml_provision.sh`)

Key non-obvious settings and their ADB keys:
- **Hand navigation** (pinch-to-interact): `settings put system enable_pinch_gesture_inputs 1`  
  — NOT `enable_home_gesture_inputs` (that is the fist-to-home gesture only)
- **Auto-brightness off**: `settings put system screen_brightness_mode 0`
- **Brightness**: `settings put system screen_brightness 0`
- **Screen timeout never**: `settings put system screen_off_timeout 2147483647`

## Key Files

| File | Purpose |
|------|---------|
| `lib/show_config.sh` | Sourced by every main script; resolves + validates the active show |
| `shows/<id>.conf` | Per-show config (committed); `shows/KAGAMI.conf` = original values; `shows/EXAMPLE.conf` = template |
| `ml_show.sh` | Select/create the active show (`use`, `init`, status) |
| `.active_show` | Machine's selected show id (gitignored, set by `ml_show.sh use`) |
| `devices/<id>.txt` | Per-show fleet IPs (gitignored, operator-managed) |
| `devices.txt` | Legacy fleet IPs — read-only fallback when no per-show file exists yet (gitignored) |
| `provisioned_devices.csv` | Append-only device tracking log (gitignored) |
| `authorized_keys/` | ADB public keys for all operator machines |
| `authorized_keys/adbkey_kagami_fleet` | Shared fleet private key (gitignored) |
| `os_images/1.4.1/` | OS partition images from ML Hub (gitignored) |
| `builds/` | APKs and show assets (gitignored) |
| `fleet_dashboard.html` | Visual dashboard, fed by `ml_status.sh --json` |
| `apps_script/Code.gs` | Google Apps Script for Sheets integration |
| `logs/` | Per-device deploy logs (gitignored) |
| `status/` | Per-run status JSON from `ml_status.sh` (gitignored) |

## Git Workflow

- `main`: Production (PRs only)
- `dev`: Active development

All changes go through `dev` → PR → `main`. After merging to `main`, tag with semantic version (`v0.x.x`) and push the tag. Operators update via `./update.sh`.
