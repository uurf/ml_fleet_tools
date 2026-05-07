# KAGAMI Fleet Pipeline — Tin Drum
### Device Provisioning & Deployment Overview

---

## Phase 1 — Provisioning (bench, USB cable, one device at a time)

Handled by `ml_os_flash.sh` → `ml_provision.sh` automatically.

- Flash OS 1.4.1
- Inject ADB keys (no USB debugging dialog on subsequent connections)
- Skip OOBE / setup wizard
- Apply all device settings (brightness, WiFi, battery, display, animations, etc.)
- Connect to KAGAMI WiFi
- Create `/sdcard/Kagami/data/` (required by asset copy script)
- Update tracking sheet automatically

**Manual headset steps per device (~5 min):**

*Controller*
- Connect controller to Compute Pack via USB-C — firmware update screen appears, controller LED flashes white while updating (~2 min). Disconnect when done.

*Laptop connection*
- Reconnect Compute Pack to laptop via USB-C — two dialogs will appear in headset:
  - **Allow USB debugging** → check "Always allow from this computer" → Allow
  - **USB Device Detected** → OK

*Battery*
- Settings → Battery → Compute Pack Standby → **Off**

*Display*
- Settings → Display → Brightness → adjust to between the *t* and *n* in the "Brightness" label
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
- Sets `com.tindrum.kiosk` as the default home app on all devices automatically

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

## Phase 3 — Asset Loading (USB-C drive, per device)

Handled by the kiosk APK's built-in copy script — no laptop required.

- Load all show assets onto a USB-C drive
- Connect drive to each device's Compute Pack
- Kiosk script detects the drive and copies contents to `/sdcard/Kagami/data/`
- Disconnect drive and move to next device

> Multiple operators with multiple drives can run this in parallel.

---

## Phase 4 — Verification (WiFi, fleet-wide)

Handled by `ml_status.sh` — confirms fleet is show-ready.

- OS version correct
- Expected APKs installed, no unexpected APKs
- `/sdcard/Kagami/data/` file count and integrity
- All settings correct (brightness, WiFi, battery, display, etc.)
- Online/offline status of all devices

```bash
./ml_status.sh
```

---

## Summary

| Phase | Tool | Connection | Who |
|---|---|---|---|
| Flash & provision | `ml_os_flash.sh` → `ml_provision.sh` | USB | 1 operator per device |
| APK install (first run) | `ml_provision.sh` → `ml_deploy.sh` | USB | 1 operator per device |
| Asset loading | Kiosk copy script | USB-C drive | Multiple operators in parallel |
| APK updates (field) | `ml_deploy.sh deploy` | WiFi | 1 operator, all devices |
| Verification | `ml_status.sh` | WiFi | 1 operator, all devices |
