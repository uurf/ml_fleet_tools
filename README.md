# ml_toolkit_tools
### Magic Leap 2 Fleet Management Toolkit — Tin Drum / KAGAMI Show

Zero-MDM fleet management for Magic Leap 2 devices. Handles OS flash, provisioning, APK/asset deployment, and fleet status monitoring via WiFi ADB.

---

## Quick start

```bash
# Clone and install
git clone https://github.com/cconnors/ml_toolkit_tools.git ~/Developer/ml_toolkit
cd ~/Developer/ml_toolkit && chmod +x install.sh && ./install.sh

# Flash and provision a device (in fastboot mode)
./ml_os_flash.sh 1.4.1
```

See **SETUP.md** for full setup instructions and **PROVISIONING.md** for per-device workflow.

---

## Scripts

| Script | Purpose |
|---|---|
| `install.sh` | One-command environment setup for new machines |
| `ml_os_flash.sh` | Flash OS 1.4.1, inject ADB keys, skip OOBE, run provisioning |
| `ml_provision.sh` | Apply all device settings; `--check` to verify |
| `ml_deploy.sh` | Deploy APKs, push assets, launch/restart app across fleet |
| `ml_status.sh` | Collect OS/APK/settings status from all online devices |
| `fleet_dashboard.html` | Visual dashboard — load JSON from `ml_status.sh --json` |

---

## Fleet structure

```
ml_toolkit/
├── os_images/                        ← gitignored — download from ML Hub
│   └── 1.4.1/
├── builds/                           ← gitignored — APKs and assets
├── authorized_keys/
│   ├── adbkey                        ← fleet private key (distribute to all machines)
│   └── *.pub                         ← public keys per machine
├── devices.txt                       ← gitignored — one IP per line
└── provisioned_devices.csv           ← gitignored — serial/MAC/IP/device# log
```

---

## New machine setup

Any machine that needs to connect to fleet devices must use the shared fleet ADB key:

```bash
cp authorized_keys/adbkey ~/.android/adbkey
chmod 600 ~/.android/adbkey
ssh-keygen -y -f ~/.android/adbkey > ~/.android/adbkey.pub
adb kill-server && adb start-server
```

Or just run `./install.sh` — it handles this automatically.

---

## Target configuration

| Setting | Value |
|---|---|
| Target OS | 1.4.1 |
| WiFi SSID | KAGAMI |
| App package | com.tindrum.kagami |
| ADB port | 5555 |

---

## What the pipeline does automatically

- OS flash to 1.4.1 via `fastboot format` + `flashall_amd.sh`
- macOS compatibility patches (Apple Silicon + Intel)
- ADB key injection — no USB debugging dialog on subsequent connections
- OOBE/setup wizard bypass — device boots straight to home
- All scriptable settings (brightness, WiFi, battery saver, bluetooth, animations, etc.)
- Google Sheets tracking — updates status, checkboxes, and notes automatically

## What requires manual headset steps (per device)

1. Controller USB-C → firmware update (~2 min)
2. Settings → Battery → Compute Pack Standby → Off
3. Settings → Display → Display Override → Off
4. Settings → Display → Segmented Dimming → Off
5. Settings → System → Advanced → OS Updater → Check for updates → Never

---

## Google Sheets integration

The scripts automatically update the Kagami Osaka - Device status sheet via a Google Apps Script endpoint. The Apps Script code is in `apps_script/Code.gs`.

Actions sent to the sheet:
- `flash_start` — serial written, status set to "Firmware update in progress"
- `flash_complete` — OS 1.4.1 checkbox checked
- `provision_start` — status set to "Configuration in progress"
- `provision_complete` — all auto-configured setting checkboxes checked

---

## Compatibility

- macOS Intel and Apple Silicon (M1/M2/M3)
- Requires Homebrew bash 5+ (`mapfile` not available in macOS default bash 3.2)
- Python 3 required for Google Sheets integration (included with macOS 12+)
