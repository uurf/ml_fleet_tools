# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ml_toolkit** is a zero-MDM fleet management system for Magic Leap 2 (ML2) XR headsets, built for the KAGAMI show (Tin Drum). It handles the complete device lifecycle over ADB: OS flashing via fastboot, device provisioning, APK/asset deployment, and fleet monitoring over WiFi ADB.

**Target OS**: ML2 1.4.1 (Build B3E.230928.10-R.098)  
**Show App**: com.tindrum.kagami  
**Kiosk/Home App**: com.tindrum.kiosk  
**WiFi SSID**: KAGAMI / KAGAmius  
**ADB Port**: 5555 (WiFi)

## Running Scripts

There is no build system. All scripts are standalone bash and run directly:

```bash
./install.sh                        # First-time machine setup (macOS only, Homebrew)
./update.sh                         # Pull latest from main, protect fleet key
./ml_os_flash.sh [version] [path]   # Flash OS, pre-auth ADB, skip OOBE, chain to provision
./ml_provision.sh [--check|--discover]  # Apply device settings, WiFi, permissions
./ml_deploy.sh <command> [options]  # Fleet APK install, asset push, app management
./ml_status.sh [--json|--csv|--failures|--fix]  # Parallel status collection
./utilities/ml_ssd_copy.sh          # Copy show assets from USB-C SSD to fleet
```

**Shell requirement**: Scripts require bash 5+ (macOS ships with bash 3.2; Homebrew bash is required). `install.sh` handles this.

**Linting/testing**: There is no test suite. Manual testing is done against real devices. Use `shellcheck` if available for static analysis of shell scripts.

## Architecture

### Script Pipeline (in order)

```
ml_os_flash.sh → ml_provision.sh → ml_deploy.sh → ml_ssd_copy.sh → ml_status.sh
```

Each script in the chain auto-runs the next when successful. They communicate via environment variables: `ANDROID_SERIAL`, `DEVICE_NUMBER`, `CASE_NUMBER`, `OPERATOR_INITIALS`, `CHAIN_DEPLOY`.

### Update Gate

Every main script (flash, provision, deploy, status) fetches `origin/main` at startup and **hard-stops if the local HEAD differs**. This ensures all operators run the same version. The check is bypassed when a script is called by another script (detected via env var like `ANDROID_SERIAL`).

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

## Key Files

| File | Purpose |
|------|---------|
| `devices.txt` | Fleet IPs, one per line (gitignored, operator-managed) |
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
