# KAGAMI Fleet Pipeline — Tin Drum
### Device Provisioning & Deployment Overview

---

## Phase 1 — Provisioning (bench, USB cable, one device at a time)

Handled by `ml_os_flash.sh` → `ml_provision.sh` automatically. All show-specific values come from the active show's `shows/<id>.conf` — the same script handles every show.

- Flash OS 1.4.1
- Inject ADB keys (suppresses the dialog on userdebug builds only — on the production ML2 1.4.1 user build the operator still taps "Allow USB debugging" once per (laptop, device) pair; the shared fleet key then covers all other operator laptops)
- Skip OOBE / setup wizard
- Apply all device settings — brightness (`SHOW_BRIGHTNESS`), WiFi (`SHOW_SSID`), battery, hand navigation, animations, etc.
- Connect to the active show's WiFi (`SHOW_SSID`)
- Update the active show's tracking sheet automatically (per `SHOW_SHEETS_URL`)

**Manual headset steps per device (~3 min):**

*Controller*
- Connect controller to Compute Pack via USB-C — firmware update screen appears, controller LED flashes white while updating (~2 min). Disconnect when done.

*Laptop connection*
- Reconnect Compute Pack to laptop via USB-C — two dialogs will appear in headset:
  - **Allow USB debugging** → check "Always allow from this computer" → Allow
  - **USB Device Detected** → OK

*Battery*
- Settings → Battery → Compute Pack Standby → **Off**

*Display* — Brightness itself is now set over ADB from `SHOW_BRIGHTNESS`; only the ML2-specific items below still need a headset tap:
- Settings → Display → Display Override → **Off**
- Settings → Display → Global Dimming → just below maximum, even with the *h* in "light"
- Settings → Display → Segmented Dimming → **On**
- Settings → Display → Maximum Dimming → just below maximum, even with the *l* in "display"

*System*
- Settings → System → Advanced → OS Updater → **Never**

---

## Phase 2 — APK Install & Updates

Handled by `ml_deploy.sh deploy`, called automatically by `ml_provision.sh` at the end of provisioning (USB, first run). For subsequent updates in the field, run from any laptop on the network over WiFi.

- Connects to all devices automatically
- Prompts operator to select which APK(s) to install from `builds/`
- Installs selected APKs across all devices in parallel
- Sets `com.tindrum.kiosk` as the default home app on all devices automatically (kiosk *package* is shared across shows; the *versionName* baked into each build is per-show — `SHOW_KIOSK_VERSION` flags a mis-loaded kiosk on the dashboard)

> **First run (bench):** called by `ml_provision.sh` over USB — no extra step needed.
> **Updates in the field (WiFi):**
> ```bash
> # Full fleet
> ./ml_deploy.sh deploy
> 
> # Single device
> ./ml_deploy.sh -d <ip> deploy
> ```

---

## Phase 3 — Asset Loading (USB-C drive on the headset)

Normal path: the show APK detects the attached USB-C SSD on launch and copies the asset payload from SSD → `/sdcard/$SHOW_DATA_DIR/data/` internally, unattended. Operator just attaches the SSD and waits.

`utilities/ml_ssd_copy.sh` is a **fallback** for cases where the show APK isn't handling the copy itself (e.g. a fresh/bench device without the show installed yet). It copies show data from the SSD to every reachable device in the active show's fleet list, in parallel, over WiFi ADB.

```bash
./utilities/ml_ssd_copy.sh              # every device in the active show's fleet list
./utilities/ml_ssd_copy.sh -d <ip>      # single device
```

- Script discovers the SSD mount, lists every `[showName]_data/` directory on it, prompts the operator to select one if multiple, copies to `/sdcard/[showName]/data/` on each device in parallel.

> Multiple laptops running `ml_ssd_copy.sh` against different device subsets can run in parallel to speed up large fleets.

---

## Phase 4 — Verification (WiFi, fleet-wide)

Handled by `ml_status.sh` — confirms fleet is show-ready.

- OS version correct (per `SHOW_EXPECTED_OS`)
- Expected show APK installed at the right version (`SHOW_EXPECTED_APK`); no unexpected `com.tindrum.*` packages
- Expected kiosk versionName matches (`SHOW_KIOSK_VERSION`)
- `/sdcard/$SHOW_DATA_DIR/` contains the required entries (per `SHOW_DATA_REQUIRED`) and no extraneous junk
- All ADB-settable settings correct (brightness from `SHOW_BRIGHTNESS`, WiFi joined to `SHOW_SSID`, BT on, stay-awake, hand nav, dev mode, USB debugging, auto-update off)
- Online/offline status of every device in the show's expected fleet list (offline devices surface as red OFFLINE rows on the dashboard)

```bash
./ml_status.sh
```

> For the full flag set (`--json`, `--csv`, `--failures`, `--fix`, `--expected-os/apk`, `--package`) and the dashboard JSON-export pattern, see **PROVISIONING.md → ml_status.sh flags**.

> **Running the show day-to-day** (recurring health sweeps, the dashboard, field APK updates, two concurrent shows) is its own runbook: see **FIELD_OPS.md**.

---

## Summary

| Phase | Tool | Connection | Who |
|---|---|---|---|
| Flash & provision | `ml_os_flash.sh` → `ml_provision.sh` | USB | 1 operator per device |
| APK install (first run) | `ml_provision.sh` → `ml_deploy.sh` | USB | 1 operator per device |
| Settings remediation | `ml_provision.sh --fleet` | WiFi | 1 operator, all devices |
| Asset loading | `ml_ssd_copy.sh` | WiFi + USB-C SSD | 1 operator, all devices |
| APK updates (field) | `ml_deploy.sh deploy` | WiFi | 1 operator, all devices |
| Verification | `ml_status.sh` | WiFi | 1 operator, all devices |
