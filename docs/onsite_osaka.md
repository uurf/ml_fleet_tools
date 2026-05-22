# On-Site Runbook — Osaka (VS Umeda)

Two shows, two fleets, two adjacent rooms in VS Umeda, Osaka.

| Show         | Room       | SSID          | Fleet                          | Origin                                          |
|--------------|------------|---------------|--------------------------------|-------------------------------------------------|
| `KAGAMI`     | Room A     | `KAGAMI`      | 202 devices                    | Shipped from Pittsburgh, fully provisioned      |
| `KAGAMI_BLUE`| Room B     | `KAGAMI_BLUE` | 180 devices                    | Already in Osaka, provisioned for a prior KAGAMI run; need full reconfigure |

Operators are expected to keep one laptop per show (laptop's WiFi must match the SSID of the fleet being worked on, since the fleet operates over WiFi ADB).

---

## 0. Prerequisites

Before any on-site work begins:

- **Artifacts on the operator laptop**
  - Repo cloned, `./install.sh` already run on the machine (Homebrew bash 5+, fleet `~/.android/adbkey`, ADB/fastboot, etc.)
  - `./update.sh` run within the last day so HEAD matches `origin/main` (the update gate will hard-stop main scripts otherwise)
  - `builds/` contains the show APK for the show this laptop is working on (`KAGAMI` APK on the KAGAMI laptop; `KAGAMI_BLUE` APK on the BLUE laptop)
- **Network**
  - Both venue SSIDs (`KAGAMI`, `KAGAMI_BLUE`) are up before the first device is touched
  - Laptop is joined to the SSID matching the show it is working on
- **Show config**
  - `shows/KAGAMI.conf` already exists (committed) and matches the venue's `KAGAMI` SSID/password — confirm before first use
  - `shows/KAGAMI_BLUE.conf` is created during one-time setup below

---

## 1. One-time on-site setup (per laptop)

Each laptop is dedicated to one show. Run these once per laptop.

### KAGAMI laptop

```bash
./ml_show.sh use KAGAMI
```

Confirm `shows/KAGAMI.conf` matches the venue: open it and verify `SHOW_SSID`, `SHOW_WIFI_PASSWORD`, `SHOW_WIFI_SECURITY`, `SHOW_PACKAGE`, and (if set) `SHOW_EXPECTED_APK` / `SHOW_EXPECTED_OS`. If any venue-specific value has changed since Pittsburgh, edit the conf and commit on `dev`.

### KAGAMI_BLUE laptop

```bash
./ml_show.sh init
```

When prompted, supply:

- Show id: `KAGAMI_BLUE`
- `SHOW_SSID`: `KAGAMI_BLUE`
- `SHOW_WIFI_PASSWORD`: (venue value)
- `SHOW_WIFI_SECURITY`: typically `wpa2`
- `SHOW_PACKAGE`: BLUE show APK package name
- `SHOW_BRIGHTNESS`: raw `screen_brightness` value (KAGAMI uses `12`; accept the default unless BLUE has a different setpoint from the show)
- `SHOW_DATA_DIR`: top-level dir under `/sdcard/` the BLUE APK reads from (KAGAMI uses `Kagami`; confirm BLUE's path before answering)
- `SHOW_DATA_REQUIRED`: entries under `/sdcard/$SHOW_DATA_DIR/` that MUST be present (typically the asset dir copied from the SSD). Default: `data`. Missing any of these is a dashboard red flag.
- `SHOW_DATA_OPTIONAL`: entries the show APK creates at runtime (logs, textures, registered apriltag config). Default: `applogs textures config.json marker-space-config.json`. Absence is fine — a bench-fresh device that hasn't run the show won't have these yet. Anything found under the data dir that's in neither REQUIRED nor OPTIONAL is flagged as extraneous.
- `SHOW_DISK_WARN_PCT`: dashboard red-flag threshold for `/sdcard` usage (KAGAMI uses `60`)
- `SHOW_EXPECTED_APK` / `SHOW_EXPECTED_OS`: optional but recommended for `--check` drift detection

Accept the offer to make `KAGAMI_BLUE` the active show. Commit `shows/KAGAMI_BLUE.conf` on `dev` and push so other operators inherit it via `./update.sh`.

> **Open item — per-show kiosk:** `CLAUDE.md` currently states `com.tindrum.kiosk` is shared across shows. If `KAGAMI_BLUE` ships its own kiosk, `shows/<id>.conf` needs a new `SHOW_KIOSK_PACKAGE` field and `ml_provision.sh` needs a corresponding change. Flag before bench-ops start if this is the case.

---

## 2. KAGAMI_BLUE — Osaka 180 bench flow

The 180 devices in Osaka are already on ML2 1.4.1 with OOBE dismissed (an operator manually completed OOBE during their prior KAGAMI run). They are **not** flashed on site. The bench-op pipeline below brings them to the same readiness bar as the Pittsburgh 202.

### Per device

1. **USB connect** the device to the laptop.
2. **Authorize the fleet ADB key on the headset.** A dialog appears in the headset:
   "Allow USB debugging?" — check **Always allow from this computer**, then **Allow**.
   - This step is unavoidable. The ML2 user build of 1.4.1 does not honor pre-seeded `/data/misc/adb/adb_keys`, so every new (laptop, device) pair requires one manual tap. Once authorized, the fleet adbkey is trusted for that device for all operator laptops.
3. **Run provision-and-deploy in one shot:**

   ```bash
   ./ml_provision.sh --deploy
   ```

   What this does:
   - Applies all ADB-settable settings (brightness, screen timeout, hand navigation, etc.)
   - Joins the device to `KAGAMI_BLUE` WiFi (credentials from `shows/KAGAMI_BLUE.conf`)
   - Prints a manual-headset checklist (Display Override, Segmented Dimming, Global/Max Dimming, Compute Pack Standby = Off, OS Updater = Never). Operator completes those in the headset UI, then presses Enter at the gate.
   - Runs `ml_deploy.sh --all` over USB, installing the BLUE show APK and any supporting payloads bundled in the deploy.
   - Enables WiFi ADB as its final step. The USB connection drops at that point — this is expected; the device is now on `KAGAMI_BLUE` and reachable over WiFi ADB.
4. **Record the device IP** printed at the end of provision in `devices/KAGAMI_BLUE.txt` (one IP per line). The line is also printed for copy-paste.
5. **Attach the USB-C SSD** containing the BLUE show data to the device. The show APK detects the SSD on launch and copies the asset payload from SSD → `/sdcard` internally, unattended. Leave the SSD attached until the in-device copy finishes (the APK indicates progress on the headset).
   - `./utilities/ml_ssd_copy.sh` is **not** needed for this step. It is a fallback for cases where the show APK is not doing the copy itself.
6. **Verify:**

   ```bash
   ./ml_status.sh -d <ip>
   ```

   or check the fleet dashboard once the device is in `devices/KAGAMI_BLUE.txt`.

### Throughput

The bench process per device is faster than Pittsburgh's because there is no flash step. Limiting factors are the manual headset taps (fleet-key auth + manual settings checklist) and the SSD copy duration.

---

## 3. KAGAMI — Pittsburgh 202 on-site flow

The 202 arrive in Osaka fully provisioned for `KAGAMI` (settings applied, show APK installed in Pittsburgh, on the Pittsburgh `KAGAMI` SSID config). They do **not** need re-provisioning unless drift is detected.

### Setup
- Connect the KAGAMI laptop to the venue's `KAGAMI` SSID.
- Confirm `shows/KAGAMI.conf` matches the venue. If the venue's `KAGAMI` SSID differs from Pittsburgh's, this is **not** a simple network swap — every device's stored WiFi credentials point at the Pittsburgh SSID and the devices will need a USB-bench WiFi update like the BLUE 180. Assume same SSID unless confirmed otherwise on the day.

### Per device

1. **Power on** the device. It joins the venue's `KAGAMI` WiFi automatically (same SSID as Pittsburgh).
2. **Add the device IP** to `devices/KAGAMI.txt` if not already present.
3. **Fleet check for drift:**

   ```bash
   ./ml_provision.sh --fleet --check
   ```

   Read-only — reports which settings have drifted.

   **Expected drift on first run:** all 202 will report `screen_brightness` drift (current value `0`, expected `12`). The 202 were provisioned in Pittsburgh before `SHOW_BRIGHTNESS` was promoted to show config — the value moved from `0` to `12` in the same change. To remediate the whole fleet in one pass:

   ```bash
   ./ml_status.sh --fix
   ```

   `--fix` writes `screen_brightness_mode=0` first (so the ML2 doesn't ambient-recompute the value back) and then sets `screen_brightness=$SHOW_BRIGHTNESS` on any device that has drifted. Re-run `./ml_provision.sh --fleet --check` after to confirm clean. For any other settings that drifted (rare), USB connect the offending device and re-bench (`./ml_provision.sh`, no `--deploy` if APK is current).
4. **APK refresh (if needed).** If a newer KAGAMI APK has landed in `builds/` since Pittsburgh:

   ```bash
   ./ml_deploy.sh deploy-all
   ```

5. **Attach SSD per device** if any asset payload differs from Pittsburgh's. Show APK handles the in-device copy. Skip if the Pittsburgh copy is still current.
6. **Verify** via `./ml_status.sh` and the dashboard.

---

## 4. Cross-show reconfigure (10s of devices)

A device originally provisioned for show A needs to run show B. Expected scale: tens of devices, not hundreds. Always bench-op for a show change — do not attempt a wifi-only re-point.

### Procedure

1. Move the device to the laptop for the **target** show.
2. USB connect → operator taps "Allow USB debugging" if this is the first time this laptop has seen this device.
3. With the target show active on the laptop (`./ml_show.sh use <target_show>` already in effect):

   ```bash
   ./ml_provision.sh --deploy
   ```

   This re-applies settings, swaps WiFi to the target show's SSID, and installs the target show's APK in one shot.
4. Remove the device from the **source** show's `devices/<source>.txt` and add it to the **target** show's `devices/<target>.txt`.
5. Attach SSD with the target show's asset payload; show APK handles the copy.
6. Verify on the target show's network.

> A laptop can temporarily act on the other show without changing its `.active_show` by setting the `ML_SHOW` env var for a single command (e.g. `ML_SHOW=KAGAMI ./ml_status.sh`). Useful for read-only spot checks across shows from one laptop. **Do not** use this to bench-op cross-show — the laptop's WiFi has to match the SSID of the fleet being acted on, and bench-op modifies WiFi state, which is destructive if pointed at the wrong show.

---

## 5. Show-day monitoring

Per show, on the laptop joined to that show's SSID:

```bash
./ml_status.sh                  # human-readable
./ml_status.sh --json           # machine output → fleet_dashboard.html
./ml_status.sh --failures       # only devices with problems
./ml_status.sh --fix            # remediate drift in-place (use sparingly)
```

The fleet dashboard (`fleet_dashboard.html`) reads `--json` output and is the primary at-a-glance view during showtime. **Its job is trouble identification, not drift mitigation.** A device shows red on the dashboard when something will affect the show: wrong OS or APK version, expected show data missing, extraneous content under the show data dir (e.g. recursive `data/data`), extraneous `com.tindrum.*` packages installed, `/sdcard` usage above `SHOW_DISK_WARN_PCT`, or hand-navigation off. Drift/compliance (Sleep, Dev mode, USB debugging, brightness, BT) is **not** on the dashboard — that's `ml_provision.sh --check` / `ml_status.sh --fix` territory.

Load the dashboard:

```bash
./ml_status.sh --json > status/latest.json
# then open fleet_dashboard.html in a browser and drag status/latest.json onto it
```

---

## 6. Open items / risks

- **Per-show kiosk** — if `KAGAMI_BLUE` ships its own kiosk app, `shows/<id>.conf` needs a `SHOW_KIOSK_PACKAGE` field and a matching change in `ml_provision.sh`. Confirm before bench-ops.
- **`shows/KAGAMI.conf` SSID match** — if the venue's `KAGAMI` SSID differs from Pittsburgh's, the 202 need a bench-op WiFi update just like the BLUE 180. Confirm SSID parity on day 1.
- **Fleet-key auth tap** — manual, per (laptop, device) pair, unavoidable on user build 1.4.1. Plan operator time accordingly during bench-ops.
- **Update gate vs `dev` branch** — every main script hard-stops if local HEAD differs from `origin/main`. On-site work should run from `main`. If hot-fixes are made on site, merge `dev` → `main`, tag, and re-run `./update.sh` on every operator laptop before continuing.
