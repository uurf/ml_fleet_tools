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

---

## [v0.6.0] — planned — Deploy workflow

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
