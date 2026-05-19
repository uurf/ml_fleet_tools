# Changelog
### ML Fleet Toolkit — Tin Drum / KAGAMI

All notable changes to this project will be documented here.
Format: [Semantic Versioning](https://semver.org) — `major.minor.patch`

- **Major** — breaking changes, new show configuration
- **Minor** — new features, new scripts
- **Patch** — bug fixes, wording changes, documentation updates

---

## [Unreleased]

_Work in progress on `dev` branch. Merge to `main` via pull request when ready to release._

### Fixed
- `ml_deploy.sh`: kiosk-as-home was silently lost after the post-install reboot (#36). `do_set_home` now (a) fails loudly if `com.tindrum.kiosk` isn't installed, (b) verifies the kiosk actually resolves as the HOME activity (ML2 has three competing HOME activities), retrying until PackageManager applies it, and (c) returns a real ✗ instead of a false ✓ — `adb shell` does not propagate the inner exit code on ML2. Deploy now settles ~10s after setting home so PackageManager flushes the preference to disk before the reboot races it.
- `lib/show_config.sh`: no longer dead-ends with "no show configured" when the choice is unambiguous. One configured show is auto-selected; with multiple, an interactive run shows a numbered picker and continues in-process (no separate `./ml_show.sh use` step). Non-interactive callers (`--json`, fleet workers) still hard-stop, keeping machine-readable output safe.

---

## [v0.6.6] — 2026-05-15 — Hand navigation fix and doc updates

### Fixed
- `ml_provision.sh`: Hand navigation now sets `enable_pinch_gesture_inputs` (system namespace) — the correct key for pinch-to-interact pointer navigation. Previous key (`enable_home_gesture_inputs`, secure) controls the fist-to-home gesture only and does not enable hand navigation.

### Changed
- `PROVISIONING.md`: Fixed Segmented Dimming direction (Off → On); added Global Dimming and Maximum Dimming slider steps; added `--fleet`, `--fleet --check`, `-d <ip>`, and `ml_scan.sh` to quick reference
- `DEPLOYMENT.md`: Phase 3 now describes `ml_ssd_copy.sh`; summary table adds fleet settings remediation row
- `README.md`: Fixed Segmented Dimming direction; added Global/Max Dimming steps; updated script table with `--fleet` and `ml_scan.sh`
- `CLAUDE.md`: Updated script listing; added ADB-settable settings section documenting correct hand navigation key

---

## [v0.6.5] — 2026-05-15 — Package name fix

### Fixed
- Corrected show app package name from `com.tindrum.kagami` → `com.tindrum.kagamu` in `ml_provision.sh`, `ml_deploy.sh`, `fleet_dashboard.html`, `CLAUDE.md`, and `README.md` (`ml_status.sh` was already correct)

---

## [v0.6.4] — 2026-05-15 — Fleet settings mode

### Added
- `ml_provision.sh --fleet` — applies all ADB-settable settings to every device in `devices.txt` in parallel; buffers per-device output, prints sequentially with pass/fail summary
- `ml_provision.sh --fleet --check` — read-only settings audit across entire fleet
- `ml_provision.sh -d <ip>` — target a specific WiFi-connected device by IP

---

## [v0.6.3] — 2026-05-15 — Hand navigation enforcement

### Added
- `ml_provision.sh`: Enforces hand navigation on (`enable_home_gesture_inputs = 1`) during provisioning; verified readable/writable via ADB on 1.4.1 user build

---

## [v0.6.2] — 2026-05-15 — ml_scan.sh fix

### Fixed
- `utilities/ml_scan.sh`: `devices.txt` now written to repo root instead of `utilities/`

---

## [v0.6.1] — 2026-05-15 — Shellcheck cleanup

### Fixed
- `ml_os_flash.sh`: `find | xargs -I{}` → `find -exec` (SC2038 — handles filenames with spaces)
- `ml_status.sh`, `utilities/ml_ssd_copy.sh`: `PIDS=($(…))` → `mapfile -t PIDS < <(…)` (SC2207 — word-splitting safe)

### Removed
- Dead variables: `WANT_STAY_AWAKE/WIFI/BT/DEV_MODE/USB_DEBUG/AUTO_UPDATE`, `WARN`, `s_bright`, `v` in `ml_status.sh`; `YELLOW` in `update.sh`; `TARGET_OS` in `ml_provision.sh`

### Added
- `utilities/ml_scan.sh` — scans local network for ML2 devices on port 5555, prompts to confirm, writes discovered IPs to `devices.txt`

---

## [v0.6.0] — 2026-05-15 — Deploy workflow validated end-to-end

### Fixed
- `ml_provision.sh`: Restored chain deploy — `--deploy` flag triggers APK install over USB immediately after provisioning; `ml_os_flash.sh` passes the flag when chaining
- `ml_provision.sh`: Deploy now runs over USB *before* `adb tcpip 5555` so the ADB connection is still authorized when APKs are installed
- `ml_provision.sh`: Operator pause added at manual steps checklist when `--deploy` is set — press Enter after completing headset steps to begin APK install
- `ml_provision.sh`: Replaced broken `stop adbd && start adbd` (via shell) with `adb tcpip 5555` (host-side) as the last USB command
- `ml_provision.sh`: All manual steps unified into `MANUAL_STEPS[]`, printed once at the end with consistent `→` delimiters
- `ml_provision.sh`: Removed `MagicLeapDimmer` service calls that don't work on 1.4.1 user build
- `ml_os_flash.sh`: `adb disconnect` before post-flash boot wait clears stale WiFi ADB sessions; `adb wait-for-device` pinned to `$SERIAL` to avoid "more than one device" error
- `ml_deploy.sh`: `cmd_deploy_all` exits cleanly with a warning when `builds/` has no APKs

### Added
- `CLAUDE.md`: Repo guidance for Claude Code sessions

---

## [v0.5.9] — 2026-05-08 — Device number mapping in dashboard

### Added
- `asset_serial_list.csv` — 200-device hardware serial → device number mapping
- `fleet_dashboard.html`: Load CSV button maps hw_serial to device number; dashboard now shows Device # and Serial columns; search by device number or serial; default sort by device number

### Changed
- `ml_status.sh`: Adds `hw_serial` (physical serial from `ro.serialno`) to per-device JSON output
- `apps_script/Code.gs`: `deploy_complete` action added — checks off kiosk, APK, and permissions columns and sets status to "Ready for asset loading"; manual-only columns (Compute Pack Standby, Display dimming, OS Updater) removed from `provision_complete` auto-check
- `docs/headset_checklist.html`: Added "Tracking sheet" section listing manual items to check off in the Google Sheet after headset steps

---

## [v0.5.8] — 2026-05-08 — Shebang fix, Intel Mac support, status improvements

### Added
- `ml_status.sh`: Tracks both Kagami and Kiosk APKs separately in JSON output and table; auto-connects all devices in `devices.txt` before collecting status
- `fleet_dashboard.html`: Separate Kagami and Kiosk columns in table, filter, and CSV export

### Fixed
- `ml_os_flash.sh`, `ml_provision.sh`, `update.sh`: Shebang changed from `#!/opt/homebrew/bin/bash` to `#!/usr/bin/env bash` — fixes execution on Intel Macs where Homebrew installs to `/usr/local`
- `install.sh`: Added Homebrew PATH setup for Intel Macs (was only handling Apple Silicon)
- `ml_status.sh`: OS version now read from `ro.build.version.lumin` (ML2-specific property) instead of `ro.build.version.release`; update-check output redirected to stderr so it doesn't pollute `--json` mode

---

## [v0.5.7] — 2026-05-07 — Checklist updates

### Changed
- `docs/flash_checklist.html`: Removed manual write-in fields (device #, case #, operator, serial) — captured by the script now; updated step wording
- `docs/headset_checklist.html`: Added Display Override step; added "Shut down device" step at end (hold Power, wait for fan to stop before casing)

---

## [v0.5.6] — 2026-05-07 — Chain deploy after provision

### Added
- `ml_deploy.sh`: `cmd_deploy_all` — non-interactive deploy that installs all APKs in `builds/`, sets kiosk as home app; triggered via `--all` flag
- `ml_provision.sh`: Chains to `ml_deploy.sh --all` at end of provisioning when called from `ml_os_flash.sh` (via `ML_CHAINED=1` env var)
- `apps_script/Code.gs`: `deploy_complete` action handler; updated column headers to match current tracking sheet layout; added Compute Pack Standby and Segmented Dimming columns

### Changed
- `ml_provision.sh`: Brightness target set to 12 (was 0)

---

## [v0.5.5] — 2026-05-07 — SSD copy utility

### Added
- `utilities/ml_ssd_copy.sh` — copies show data from a USB-C attached SSD to `/sdcard/[showName]/data` on all fleet devices; discovers `[showName]_data` directories on the SSD and prompts operator to select a show if multiple are present; single-show drives auto-confirm; supports `-d <ip>` for single device or `devices.txt` for full fleet; parallel copy with progress display

---

## [v0.5.4] — planned — Deploy workflow

- `ml_deploy.sh` tested and validated on site
- `ml_status.sh` validated against full fleet
- `fleet_dashboard.html` wired to live fleet data
- `devices.txt` populated with show-site static IPs

---

## [v0.5.2] — 2025-05-01 — Bug fixes

### Fixed
- `ml_os_flash.sh`: missing `SCRIPT_DIR` definition causing unbound variable error on startup
- `ml_provision.sh`: stray quote in USB dialog checklist causing unbound variable error

---

## [v0.5.1] — 2025-04-30 — Bug fix

### Fixed
- `ml_provision.sh`: missing `SCRIPT_DIR` definition causing unbound variable error on startup

---

## [v0.5.0] — 2025-04-30 — KAGAMI provisioning pipeline

Initial working release. Flash, provision, and sheet tracking validated end-to-end.

### Versioning roadmap
| Version | Milestone |
|---|---|
| `v0.5.x` | Bug fixes and doc updates during provisioning phase |
| `v0.6.0` | Deploy workflow tested and validated on site |
| `v1.0.0` | Full pipeline proven in production — KAGAMI opens |

### Added
- `ml_os_flash.sh` — OS flash via `flashall_amd.sh`; ADB key injection; OOBE bypass; auto-provisions after flash
- `ml_provision.sh` — full device configuration: developer mode, WiFi, battery, display, app permissions, remove old apps; `--check` and `--discover` modes
- `ml_deploy.sh` — parallel APK install, asset push, app launch/stop/restart, fleet shell commands
- `ml_status.sh` — parallel status collection; table, JSON, and CSV output; `--fix` mode
- `fleet_dashboard.html` — visual fleet dashboard fed by `ml_status.sh --json`
- `install.sh` — one-command environment setup; Homebrew, adb/fastboot, fleet ADB key
- `update.sh` — pull latest from `origin/main`; show current and new version tags
- Google Sheets integration — `flash_start`, `flash_complete`, `flash_failed`, `provision_start`, `provision_complete` actions via Apps Script
- Operator initials prompt — written to column R ("Operator name - Phase 1") in tracking sheet
- Case number prompt — clarified that Enter = matches device number or unknown
- Critical flash failure detection — distinguishes harmless `ecfw` failures from fatal partition errors (kernel, system, etc.); hard stops with loud error and `flash_failed` sheet update
- Update check at startup — all scripts fetch `origin/main` and hard-stop if behind; skips gracefully if offline
- `ml_provision.sh` skips update check when called from `ml_os_flash.sh` (env-based)
- Friendly OS version naming — `os_images/` subdirectories named by version (e.g. `1.4.1`) rather than build string; auto-selects if only one version present; prompts with numbered menu if multiple; falls back to menu if named version not found
- Version display — all scripts show current git tag in banner; `update.sh` shows before/after

### Fixed
- macOS compatibility patches for `flashall_amd.sh` (Apple Silicon + Intel): `stat`, `lsusb`, Darwin binary paths, `usbrecovery_host`
- `fastboot reboot` loop — script kicks device out of fastboot after `ecfw` failure

### Notes
- Target OS: 1.4.1 (B3E.230928.10-R.098)
- WiFi: KAGAMI / KAGAmius
- App package: com.tindrum.kagami
- Fleet ADB key: `authorized_keys/adbkey_kagami_fleet` (distributed separately)

---

*Older entries will be added here as the project history is tagged.*
