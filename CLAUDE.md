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

**Shell requirement**: Scripts require bash 5+ (macOS ships with bash 3.2; Homebrew bash is required). `install.sh` handles this. The bash-5 guard (`lib/require_bash5.sh`) is sourced by the device-facing scripts (`ml_os_flash`/`ml_provision`/`ml_deploy`/`ml_status`/`ml_show`) which use bash-5 features.

> **Bootstrap guardrail (learned the hard way — caused a 17/18-laptop fleet outage):** `install.sh` and `update.sh` are the bootstrap/maintenance scripts and **must stay bash-3.2-safe** — no `mapfile`/assoc-arrays/`${x^^}`, and **never source the bash-5 guard.** A bootstrap script must never require the very thing it exists to install/deliver, or it deadlocks the exact machines that need it (e.g. a guarded `update.sh` can't pull its own fix on a 3.2 laptop). Relatedly, to detect a *modern* bash, check `${BASH_VERSINFO[0]} -ge 5` or the binary at `$(brew --prefix)/bin/bash` — **never `command -v bash`**, which always finds macOS's stock 3.2 `/bin/bash` and silently skips `brew install bash`.

**Linting/testing**: There is no test suite. Manual testing is done against real devices. Use `shellcheck` if available for static analysis of shell scripts.

## CLI Conventions

Argument grammar follows a git-style rule. It is consistent but was previously
undocumented (so each script can look like its own dialect — it isn't):

- **Verb-dispatch scripts take a bare subcommand** as the first positional, then
  `case`-dispatch it. Use when the script selects between *distinct actions*:
  - `ml_deploy.sh connect | deploy | deploy-all | status | shutdown`
  - `ml_show.sh use | init | status`
  - The action is a bare word, **not** a flag: `ml_deploy.sh connect`, never `--connect`.
- **Single-purpose scripts take `--flags`** that tune one implicit job (the verb
  *is* the script, so there is no subcommand):
  - `ml_provision.sh --fleet --check --deploy` (verb is always "provision";
    `--deploy` is a modifier = "also chain into deploy", not an action)
  - `ml_status.sh --json --csv --failures --fix`
  - `utilities/ml_scan.sh --subnet --append`
- **Short `-x` options are always value/param options**, never the action:
  `-d <ip>`, `-f <file>`, `-j <n>`.
- **`ml_os_flash.sh` is pure positional** (`[version] [path]`) — one job, no modes.
- `ml_deploy.sh` deliberately **mixes both**: a bare subcommand (*which* action)
  plus modifier flags `--all` / `-d` / `-f` / `-j` (*how* to run it). This is the
  most confusable surface — the subcommand is still a bare word.

New scripts should follow this: bare subcommands only for true verb dispatch,
`--flags` for behavior modifiers, `-x` for value options.

### Default scope (single device vs. whole fleet)

Whether a script acts on one device or the whole fleet by default is also a
rule, not arbitrary: **the default is the script's *primary* operating context;
the other scope is an explicit flag.**

- **Fleet-by-default** — jobs that only make sense fleet-wide over WiFi:
  `ml_status.sh`, `ml_deploy.sh`, `utilities/ml_scan.sh`. Narrow to one device
  with `-d <ip>` where supported.
- **Single-device-by-default, `--fleet` opt-in** — scripts whose primary job is
  the bench/USB per-device flow: `ml_provision.sh` (one USB device, or `-d <ip>`;
  `--fleet` is the add-on for fleet drift remediation).
- **Single-device only** — `ml_os_flash.sh`: USB, one device at a time, no fleet
  concept at all.

`ml_provision.sh` is the one that straddles both contexts (bench provisioning
*and* fleet drift remediation), which is why its scope needs the explicit
`--fleet` flag — and why behavior that's fine in the flash→provision→deploy
chain (e.g. removing apps) is wrong for a standalone fleet remediation pass.

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

It sources `shows/<id>.conf` (committed). Required fields (resolver hard-stops if any is missing): `SHOW_SSID`, `SHOW_WIFI_PASSWORD`, `SHOW_WIFI_SECURITY`, `SHOW_PACKAGE`, `SHOW_BRIGHTNESS`, `SHOW_DATA_DIR` (top-level dir under `/sdcard/` the show APK reads from, e.g. `Kagami`), `SHOW_DISK_WARN_PCT` (dashboard red-flag threshold for `/sdcard` usage). Optional: `SHOW_EXPECTED_APK`/`SHOW_EXPECTED_OS`/`SHOW_NAME`; `SHOW_DATA_REQUIRED` (space-separated entries under `/sdcard/$SHOW_DATA_DIR/` that **must** be present — missing any = dashboard trouble; defaults to `data`); `SHOW_DATA_OPTIONAL` (entries the show APK creates at runtime — absence is fine; defaults to `applogs textures config.json marker-space-config.json`). Anything found under the data dir that is in neither list counts as extraneous. `SHOW_REMOVE_PACKAGES` (space-separated packages from *other* shows to uninstall during provisioning — e.g. `KAGAMI_BLUE` removes the RED show app `com.tindrum.kagamu`; seeds `ml_provision.sh`'s `REMOVE_PACKAGES`, applied only in the provision pass, never `--check`). The resolver validates, then exports `SHOW_*` plus `SHOW_DEVICES_FILE`. Scripts assign their previously-hardcoded vars from `SHOW_*` (e.g. `ml_provision.sh`'s `WIFI_SSID="$SHOW_SSID"`). `shows/KAGAMI.conf` reproduces the original hardcoded values plus the show-spec brightness (`12`) and data dir (`Kagami`).

**Per-show devices file**: `devices/<id>.txt` (gitignored) is the canonical fleet list (`ml_scan.sh`/`ml_show.sh` write it). Reads fall back to legacy `devices.txt` if the per-show file doesn't exist yet, so the live fleet keeps working pre-migration. An explicit `-f <file>` still overrides.

**Confirmation**: destructive entry points (flash, provision, deploy) call `show_confirm`, which prints the resolved show and asks the operator to press Enter to proceed, or `S` to switch to another configured show via a numbered picker (`_sc_pick_show`). `show_confirm` is a silent no-op when `ML_SHOW_CONFIRMED=1` is inherited from a parent in the chain (so the operator confirms once, at flash). Read-only paths (`ml_status.sh`, `--check`) only print `show_banner` — and in `ml_status.sh` the banner goes to **stderr** so `--json`/`--csv` stdout stays machine-readable.

**On-site setup for a new show**: `./ml_show.sh init` prompts for the values, writes `shows/<id>.conf`, and offers to make it active — no hand-editing of bash on site.

**On-site runbook (Osaka, VS Umeda)**: see [`docs/onsite_osaka.md`](docs/onsite_osaka.md) for the KAGAMI / KAGAMI_BLUE two-fleet on-site procedure (Pittsburgh 202 land-and-verify; Osaka 180 bench-op for BLUE).

### ADB Pre-Authorization

On first boot after flash, `ml_os_flash.sh` attempts to inject all known public keys from `authorized_keys/` into `/data/misc/adb/adb_keys` on the device and restart `adbd`. **On secure/user builds of MLOS — including the production ML2 1.4.1 build — this injection does not actually suppress the "Allow USB debugging?" dialog.** The OS does not honor pre-seeded `adb_keys` on this build. The injection step is left in place because it would work on a non-secure build, but in production operators **must** tap "Allow USB debugging" → "Always allow from this computer" on the headset the first time any laptop connects to a given device.

What actually keeps the fleet usable across many operators is the **shared fleet key**, not the injection: `authorized_keys/adbkey_kagami_fleet` is the shared private ADB key (gitignored, distributed separately). Every operator machine installs this to `~/.android/adbkey` via `install.sh`, so every laptop presents the same identity to the device. One operator tapping "Allow" on a device authorizes the fleet key, and from then on **any** operator laptop can connect without re-prompting. `update.sh` backs the fleet key up before `git reset --hard` and restores it after.

Practical consequences:
- A single "Allow" tap is required per device, performed by the first operator to USB-connect after a flash or factory reset. After that tap, all operator laptops are good against that device.
- Flows that assume the pre-flash injection makes the bench fully unattended between flash and deploy are wrong — `ml_provision.sh`'s manual-checklist gate is also where the operator gets the "Allow" tap done before `--deploy` proceeds.
- This applies equally to the Osaka 180 bench-op flow (no flash, but same Allow-tap requirement on first connect) — see [`docs/onsite_osaka.md`](docs/onsite_osaka.md).

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
  — NOT `enable_home_gesture_inputs` (that is the fist-to-home gesture only). Read by `ml_status.sh` (exposed as `settings.hand_nav_on` in the JSON) and surfaced on `fleet_dashboard.html`; the show APK won't work without it.
- **Auto-brightness off**: `settings put system screen_brightness_mode 0`
- **Brightness**: `settings put system screen_brightness $SHOW_BRIGHTNESS` — value comes from `shows/<id>.conf` (`SHOW_BRIGHTNESS`, required; resolver hard-stops if missing). KAGAMI default is `12`. Both `ml_provision.sh` (apply + check) and `ml_status.sh` (status display + `--fix`) read from the same `SHOW_BRIGHTNESS`, so changing the conf and running `--fix` propagates the new value to the fleet.
- **Screen timeout never**: `settings put system screen_off_timeout 2147483647`

## Key Files

| File | Purpose |
|------|---------|
| `lib/show_config.sh` | Sourced by every main script; resolves + validates the active show |
| `lib/require_bash5.sh` | Sourced first by every main script; hard-stops with guidance if running under macOS's stock bash 3.2 instead of Homebrew bash 5+ (stays bash-3.2-compatible itself) |
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
| `fleet_dashboard.html` | Show-day health dashboard, fed by `ml_status.sh --json`. Surfaces trouble (wrong OS/APK, data dir missing/extraneous, extra `com.tindrum.*` APKs, `/sdcard` over `SHOW_DISK_WARN_PCT`, hand nav off). Drift/compliance lives in `ml_provision.sh --check` — not here. |
| `apps_script/Code.gs` | Google Apps Script for Sheets integration. Per-workbook bound copy; pasted into each show's bound Apps Script editor with `SHEET_TAB_NAME` const edited. The deployment URL goes in the show's `SHOW_SHEETS_URL`. |
| `docs/onsite_osaka.md` | Supervisor-grade Osaka runbook (KAGAMI + KAGAMI_BLUE). Defers per-device steps to the operator playbooks below. |
| `docs/playbook_red_osaka.html` | RED operator playbook (EN/JA, printable A4). 9 sections / 33 steps covering pre-flight → power up → scan → drift check → deploy → dashboard → shutdown → SSD assets → verify. |
| `docs/playbook_blue_osaka.html` | BLUE operator playbook (EN/JA, printable A4). Pre-flight + Phase A (USB bench, 204 devices) + Phase B (fleet flow, same shape as RED). |
| `docs/setup_checklist.html` / `docs/flash_checklist.html` / `docs/headset_checklist.html` | Per-laptop / per-device / in-headset operator checklists. EN-only. Printable. |
| `docs/auth_recovery_card.html` | Operator card (printable A4) for the one-time per-device ADB re-auth of the 204 Pittsburgh devices whose authorization expired in shipping (Android's `adb_allowed_connection_time` ~7-day timeout — see v1.2.5). Supervisor follow-on: `ml_status.sh --fix`. |
| `tests/test_sheet_integration.sh` | Device-free regression suite for the per-show Sheets plumbing. Run from anywhere. |
| `logs/` | Per-device deploy logs (gitignored) |
| `status/` | Per-run status JSON from `ml_status.sh` (gitignored) |

## Git Workflow

- `main`: Production (PRs only)
- `dev`: Active development

All changes go through `dev` → PR → `main`. After merging to `main`, tag with semantic version (`v0.x.x`) and push the tag. Operators update via `./update.sh`.
