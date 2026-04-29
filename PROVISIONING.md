# KAGAMI Device Provisioning Guide
### Tin Drum / Magic Leap 2 Fleet Management

This guide covers the complete process for flashing and provisioning a single Magic Leap 2 device. Each device takes approximately 15–20 minutes total.

---

## Before you start

- Toolkit must be installed (see **SETUP.md**)
- KAGAMI WiFi network must be broadcasting nearby
  - SSID: `KAGAMI`
  - Password: `KAGAmius`
- You need the device number and case number from the tracking sheet
- Have the controller for the device ready

---

## Overview

| Phase | Who | Time | Notes |
|---|---|---|---|
| Flash OS | Script (unattended) | ~10 min | Just watch for errors |
| Provisioning | Script (unattended) | ~2 min | Enter device/case/initials first |
| Controller update | Manual | ~2 min | Connect USB-C to compute pack |
| Headset settings | Manual | ~2 min | 4 settings to change |

---

## Step 1 — Put device into fastboot mode

The device must be powered OFF before entering fastboot.

1. If the device is on: **hold the Power button** until it shuts down completely
2. **Hold Volume Down + press Power** to start in fastboot mode
3. You'll see a fastboot indicator LED on the Compute Pack

---

## Step 2 — Connect to your laptop

Plug the USB-C cable from the Compute Pack into your laptop.

---

## Step 3 — Open Terminal and navigate to the toolkit

```
cd ~/Developer/ml_toolkit
```

---

## Step 4 — Run the flash script

```
./ml_os_flash.sh
```

Or if you skipped Step 3:

```
cd ~/Developer/ml_toolkit && ./ml_os_flash.sh
```

The script will automatically find the OS image in `os_images/` and use it. If there is more than one OS version in that folder, it will ask you to choose — but in normal operation there will only be one. You can also pass the version name directly to skip the menu, e.g. `./ml_os_flash.sh [directory name in os_images]`.

The script will detect the device and show you a confirmation screen like this:

```
ML2 OS Flash Helper

  Device:     G572XT1000XX
  State:      already in fastboot — skipping reboot

  Device:  G572XT1000XX
  From:    unknown
  To:      1.4.1

Press Enter to continue or Ctrl+C to abort...
```

---

## Step 5 — Enter device info and confirm

Press **Enter** to continue, then enter the device tracking information:

```
Device tracking
  Device number (or Enter to skip): [enter device number]
  Case number   (press Enter if it matches the device number, or is unknown): [enter case number]
  Operator initials: [your initials, e.g. JD]
```

After entering these, the script runs completely unattended for ~10 minutes. You will see partition flashing progress on screen.

> **Case number:** Enter the physical case number if it differs from the device number. Press Enter to leave it blank — the sheet will treat a blank case number as matching the device number, or unknown.
>
> **Operator initials:** These are written to the "Operator name - Phase 1" column in the tracking sheet. Enter 2–4 characters, e.g. `JD` or `MLC`.

---

## Step 6 — Wait for flash and provisioning to complete

The script will:
1. Flash all OS partitions (~10 min)
2. Reboot the device
3. Inject ADB authorization keys
4. Skip the setup wizard automatically
5. Apply all settings (brightness, WiFi, battery, display, etc.)
6. Connect to KAGAMI WiFi
7. Update the tracking sheet automatically

When complete you will see:

```
Provisioning complete.

Manual steps — put on headset and complete:
  [ ] Connect controller to device via USB-C → allow firmware update
  [ ] Connect device to laptop — two dialogs will appear:
        • "Allow USB debugging" → check "Always allow from this computer" → Allow
        • "USB Device Detected" → OK
  [ ] Settings → Battery → Compute Pack Standby → Off
  [ ] Settings → Display → Display Override → Off
  [ ] Settings → Display → Segmented Dimming → Off
  [ ] Settings → System → Advanced → OS Updater → Check for updates → Never

  Device #:      [number]
  Operator:      [initials]
  Device Serial: [serial]
  Device IP:     [ip]
```

The serial number is automatically copied to your clipboard.

---

## Step 7 — Controller firmware update

1. Connect the **controller** to the **Compute Pack** via USB-C
2. Put on the headset — you will see a firmware update progress screen
3. Wait for the update to complete (~2 minutes)
4. Disconnect the controller USB-C cable when done

---

## Step 8 — Complete manual settings in headset

Using the controller, navigate to each setting:

**Allow USB Debugging (if prompted):**

Two dialogs appear when the device is connected to the laptop.

![Allow USB debugging dialog](docs/images/usb_debugging_dialog.jpeg)

1. **"Allow USB debugging"** — check **Always allow from this computer**, then tap **Allow**

   This blesses the fleet ADB key so this dialog won't appear again for this laptop, or any other laptop using the fleet ADB key.

![USB Device Detected dialog](docs/images/usb_device_detected_dialog.jpeg)

2. **"USB Device Detected"** — tap **OK**

   This dialog appears on every connection regardless of authorization — just dismiss it.

**Battery:**
- Settings → Battery → **Compute Pack Standby → Off**

**Display:**
- Settings → Display → **Display Override → Off**
- Settings → Display → **Segmented Dimming → Off**

**System:**
- Settings → System → Advanced → OS Updater → **Check for updates → Never**

---

## Step 9 — Add device IP to fleet list

Back in Terminal, run the command shown at the end of provisioning:

```
echo '[device ip]' >> devices.txt
```

For example:
```
echo '10.0.0.45' >> devices.txt
```

---

## Step 10 — Verify and move to next device

Run a quick check to confirm all settings are correct:

```
./ml_provision.sh --check
```

All items should show ✓. The ⊙ items are the manual ones you just completed in the headset.

Disconnect the device and repeat from Step 1 for the next device.

---

## Troubleshooting

**Script says "No device found over USB"**
- Make sure the device is in fastboot mode (Volume Down + Power)
- Try a different USB-C cable or port
- Check the fastboot LED is showing on the Compute Pack

**Flash fails partway through**
- The `ecfw` partition often fails — this is normal and harmless
- The script will auto-reboot and continue
- If something else fails, run `fastboot reboot` and try again

**WiFi didn't connect**
- Make sure the KAGAMI network is broadcasting
- Run `./ml_provision.sh` again after the network is available
- Or connect manually: Settings → Network & Internet → WiFi → KAGAMI

**Tracking sheet not updating**
- Check your internet connection
- The sheet update runs silently — check the sheet directly
- If missing, the provisioned_devices.csv file on your laptop has all the data

**"No arrows" in headset UI after provisioning**
- This indicates a corrupted provisioning state
- Reflash the device: run `./ml_os_flash.sh 1.4.1` again

---

## Quick reference — Terminal commands

```bash
# Flash and provision a device (auto-selects the OS in os_images/)
./ml_os_flash.sh

# Flash a specific version (if multiple OS versions are in os_images/)
./ml_os_flash.sh 1.4.1

# Provision only (no flash)
./ml_provision.sh

# Check device settings
./ml_provision.sh --check

# Install APK on a specific device
./ml_deploy.sh -d [ip] install builds/kagami_offline.apk

# Push assets to a specific device  
./ml_deploy.sh -d [ip] push builds/assets/ /sdcard/KAGAMI/

# Check status of all devices in fleet
./ml_status.sh

# Connect to all devices over WiFi
./ml_deploy.sh connect
```
