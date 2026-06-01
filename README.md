# ml_toolkit_tools
### Magic Leap 2 Fleet Management Toolkit — Tin Drum

Zero-MDM fleet management for Magic Leap 2 devices. Handles OS flash, provisioning, APK/asset deployment, and fleet status monitoring via WiFi ADB. Multi-show: one codebase runs every Tin Drum show (KAGAMI, KAGAMI_BLUE, …) — per-show values (WiFi, app package, expected versions, tracking sheet) live in `shows/<id>.conf`, not in scripts.

---

## Quick start

```bash
# Clone and install
git clone https://github.com/uurf/ml_fleet_tools.git ~/Developer/ml_toolkit
cd ~/Developer/ml_toolkit && chmod +x install.sh && ./install.sh

# Pin this laptop to a show (one-time per machine)
./ml_show.sh use KAGAMI        # or ./ml_show.sh init for a new show

# Flash and provision a device (in fastboot mode)
./ml_os_flash.sh
```

See **SETUP.md** for full setup instructions and **PROVISIONING.md** for per-device workflow.

---

## Scripts

| Script | Purpose |
|---|---|
| `install.sh` | One-command environment setup for new machines |
| `ml_show.sh` | Select / create the active show on this laptop (`use <id>`, `init`, status) |
| `ml_os_flash.sh` | Flash OS 1.4.1, inject ADB keys, skip OOBE, run provisioning |
| `ml_provision.sh` | Single-device: apply all settings over USB; `-d <ip>` for WiFi; `--check` to verify |
| `ml_provision.sh --fleet` | Apply ADB-settable settings to every device in the active show's `devices/<show>.txt` in parallel; `--check` for fleet-wide audit |
| `ml_deploy.sh` | Deploy APKs and assets to fleet; `deploy` command connects automatically, prompts for APK selection, pushes assets, and installs |
| `ml_status.sh` | Collect OS/APK/settings status from all online devices |
| `utilities/ml_scan.sh` | Scan local network for ML2 devices on port 5555, write the active show's `devices/<show>.txt` |
| `fleet_dashboard.html` | Visual dashboard — load JSON from `ml_status.sh --json` |

---

## Fleet structure

```
ml_toolkit/
├── os_images/                        ← gitignored — created by install.sh; download OS from ML Hub
│   └── 1.4.1/                        ← name folder by version number
├── builds/                           ← gitignored — created by install.sh; APKs and assets
├── logs/                             ← gitignored — created by install.sh
├── status/                           ← gitignored — created by install.sh
├── authorized_keys/                  ← in repo
│   ├── adbkey_kagami_fleet           ← fleet private key (distribute to all machines)
│   └── *.pub                         ← public keys per machine
├── shows/                            ← in repo — one .conf per show
│   ├── KAGAMI.conf                   ← committed; SSID/password/package/etc.
│   ├── EXAMPLE.conf                  ← committed; template for new shows
│   └── <other shows>.conf            ← created via ./ml_show.sh init
├── .active_show                      ← gitignored — this laptop's selected show id
├── devices/                          ← gitignored — one file per show
│   └── <show>.txt                    ← one IP per line; built on site via ml_scan.sh
└── provisioned_devices.csv           ← gitignored — created on first use; serial/MAC/IP/device# log
```

---

## New machine setup

Any machine that needs to connect to fleet devices must use the shared fleet ADB key:

```bash
cp authorized_keys/adbkey_kagami_fleet ~/.android/adbkey
chmod 600 ~/.android/adbkey
ssh-keygen -y -f ~/.android/adbkey > ~/.android/adbkey.pub
adb kill-server && adb start-server
```

Or just run `./install.sh` — it handles this automatically.

---

## Target configuration

Shared across shows:

| Setting | Value |
|---|---|
| Target OS | 1.4.1 (B3E.230928.10-R.098) |
| Kiosk/home app | com.tindrum.kiosk |
| ADB port | 5555 |

Per-show (from `shows/<id>.conf`):

| Field | Purpose |
|---|---|
| `SHOW_SSID` / `SHOW_WIFI_PASSWORD` / `SHOW_WIFI_SECURITY` | WiFi the headsets join during provisioning |
| `SHOW_PACKAGE` | Show app package (this show's build) |
| `SHOW_BRIGHTNESS` | `screen_brightness` raw value |
| `SHOW_DATA_DIR` | Top-level dir under `/sdcard/` the show APK reads |
| `SHOW_EXPECTED_APK` / `SHOW_EXPECTED_OS` / `SHOW_KIOSK_VERSION` | Drift baselines for `ml_status.sh` / dashboard |
| `SHOW_SHEETS_URL` | Google Apps Script Web App URL for this show's tracking sheet (blank = no sync) |

KAGAMI defaults: SSID `KAGAMI`, app `com.tindrum.kagamu`, brightness `12`, data dir `Kagami`, kiosk version `1.0`.

---

## What the pipeline does automatically

- OS flash to 1.4.1 via `fastboot format` + `flashall_amd.sh`
- macOS compatibility patches (Apple Silicon + Intel)
- ADB key injection (effective on userdebug builds; ML2 1.4.1 user build still needs one "Allow USB debugging" tap per (laptop, device) pair — the shared fleet key then covers every other operator laptop)
- OOBE/setup wizard bypass — device boots straight to home
- All scriptable settings (brightness, WiFi, battery saver, bluetooth, animations, etc.)
- Google Sheets tracking — updates status, checkboxes, and notes per-show (each show's `SHOW_SHEETS_URL` points at its own workbook)

## What requires manual headset steps (per device)

1. Controller USB-C → firmware update (~2 min)
2. Settings → Battery → Compute Pack Standby → Off
3. Settings → Display → Display Override → Off
4. Settings → Display → Global Dimming → just below max
5. Settings → Display → Segmented Dimming → On
6. Settings → Display → Maximum Dimming → just below max
7. Settings → System → Advanced → OS Updater → Check for updates → Never

---

## Google Sheets integration

Per-show. Each show's tracking workbook has its own bound Apps Script project + Web App deployment; `SHOW_SHEETS_URL` in `shows/<id>.conf` points the toolkit at the right one. Source of the receiving script is `apps_script/Code.gs` (paste verbatim into each workbook's bound editor, edit `SHEET_TAB_NAME` to match that workbook's tab, deploy).

Actions sent to the sheet:
- `flash_start` — serial written, status set to "Firmware update in progress"
- `flash_complete` — OS 1.4.1 checkbox checked
- `provision_start` — status set to "Configuration in progress"
- `provision_complete` — all auto-configured setting checkboxes checked
- `deploy_complete` — kiosk script, APK install, and permissions checkboxes checked; status set to "Ready for asset loading"

Leave `SHOW_SHEETS_URL` blank in a show's conf to skip sheet sync entirely (useful for bench dry-runs or a show that doesn't have a workbook yet).

---

## Development workflow

All active development happens on the `dev` branch. `main` is protected and can only be updated via pull request.

```bash
# Make changes on dev
git checkout dev
# ... edit files ...
git add <files>
git commit -m "description"
git push origin dev

# When ready to release: open a PR on GitHub (dev → main), merge it, then tag
git checkout main
git pull origin main
git tag v1.x.x -m "release description"
git push origin v1.x.x

# Update all machines
./update.sh
```

## Compatibility

- macOS Intel and Apple Silicon (M1/M2/M3)
- Requires Homebrew bash 5+ (`mapfile` not available in macOS default bash 3.2)
- Python 3 required for Google Sheets integration (included with macOS 12+)
