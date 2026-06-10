# On-Site Runbook — Osaka (VS Umeda)

Supervisor-grade reference for the two-show on-site deploy. **Per-device operator instructions live in the playbooks** — this runbook is for coordination, not for an operator to follow step-by-step.

| Operator artifact | Audience | Format |
|---|---|---|
| [`playbook_red_osaka.html`](playbook_red_osaka.html) | RED operators | EN/JA side-by-side, printable A4 |
| [`playbook_blue_osaka.html`](playbook_blue_osaka.html) | BLUE operators (Phase A + Phase B) | EN/JA side-by-side, printable A4 |
| [`setup_checklist.html`](setup_checklist.html) | All operators — one-time per laptop | EN, printable |
| [`headset_checklist.html`](headset_checklist.html) | All operators — manual headset settings | EN, printable |

## Fleet

Two shows, two fleets, two adjacent rooms in VS Umeda, Osaka.

**Total inbound:** **204 from Pittsburgh** (firm — flashed and provisioned for KAGAMI Red before shipping) + **~180 from Hong Kong** (target; carnet / packing list not yet confirmed, and some units are expected to arrive broken). Working total ≈ 384, real total settled once HK arrives and functional triage is done.

**Allocation:** RED is sized first (80 per showtime × 2 showtimes + 20 spares = **180 firm**); BLUE gets the remainder. RED is filled entirely from the PGH-flashed 204 (which were provisioned for KAGAMI Red in PGH); BLUE is the 24 PGH-flashed leftover + however many HK units make it through triage.

| Show           | Room | SSID                  | Target count | State on arrival |
|----------------|------|-----------------------|--------------|------------------|
| `KAGAMI` (Red) | A    | `KAGAMI`              | 180 firm     | PGH-flashed and provisioned for this show; ready for fleet APK deploy + SSD asset load |
| `KAGAMI_BLUE`  | B    | `KAGAMI-Blue` (TBD)   | ~204 (= 24 PGH + ~180 HK − breakage) | 24 PGH-flashed (provisioned for Red — need re-pointing to BLUE WiFi); ~180 HK (at ML2 1.4.1, never provisioned by us, fleet key not yet trusted) — **every functional BLUE device needs USB-bench Phase A before fleet flow** |

Staffing model: ~4 operators, ideally 2 laptops each (8 stations total). Each laptop pins to one show (`./ml_show.sh use <id>`) — the laptop's WiFi must match the SSID of the fleet it is working on, since WiFi ADB is the fleet-control transport.

---

## 0. Prerequisites

Before any on-site work begins:

- **Artifacts on every operator laptop**
  - Repo cloned, `./install.sh` already run on the machine (Homebrew bash 5+, fleet `~/.android/adbkey`, ADB/fastboot, etc.) — see `setup_checklist.html`
  - `./update.sh` run within the last day so HEAD matches `origin/main` (the update gate will hard-stop main scripts otherwise)
  - `builds/` contains the show APK + kiosk APK for the show this laptop is working on, when available. Phase A on BLUE can run without builds (settings + WiFi only); Phase B requires builds.
- **Network**
  - Both venue SSIDs (`KAGAMI` and the BLUE SSID, working name `KAGAMI-Blue`) are up before the first device is touched
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

Confirm `shows/KAGAMI.conf` matches the venue: open it and verify `SHOW_SSID`, `SHOW_WIFI_PASSWORD`, `SHOW_WIFI_SECURITY`, `SHOW_PACKAGE`, `SHOW_BRIGHTNESS`, `SHOW_DATA_DIR`, `SHOW_KIOSK_VERSION`, `SHOW_SHEETS_URL`, and (if set) `SHOW_EXPECTED_APK` / `SHOW_EXPECTED_OS`. If any venue-specific value has changed since Pittsburgh, edit the conf and commit on `dev`.

### KAGAMI_BLUE laptop

```bash
./ml_show.sh init
```

When prompted, supply (supervisor confirms each value — many are TBD until the BLUE show build is locked):

- Show id: `KAGAMI_BLUE`
- `SHOW_SSID`: working name `KAGAMI-Blue` — confirm with supervisor
- `SHOW_WIFI_PASSWORD`: working value `KAGAmius` — confirm with supervisor
- `SHOW_WIFI_SECURITY`: typically `wpa2`
- `SHOW_PACKAGE`: BLUE show APK package name (ask supervisor; expected to change as BLUE builds iterate)
- `SHOW_BRIGHTNESS`: raw `screen_brightness` value (KAGAMI uses `12`; accept the default unless BLUE has a different setpoint from the show)
- `SHOW_DATA_DIR`: top-level dir under `/sdcard/` the BLUE APK reads from (KAGAMI uses `Kagami`; confirm BLUE's path before answering)
- `SHOW_DATA_REQUIRED`: entries under `/sdcard/$SHOW_DATA_DIR/` that MUST be present (typically the asset dir copied from the SSD). Default: `data`. Missing any of these is a dashboard red flag.
- `SHOW_DATA_OPTIONAL`: entries the show APK creates at runtime (logs, textures, registered apriltag config). Default: `applogs textures config.json marker-space-config.json`. Absence is fine — a bench-fresh device that hasn't run the show won't have these yet. Anything found under the data dir that's in neither REQUIRED nor OPTIONAL is flagged as extraneous.
- `SHOW_DISK_WARN_PCT`: dashboard red-flag threshold for `/sdcard` usage (KAGAMI uses `60`)
- `SHOW_EXPECTED_APK` / `SHOW_EXPECTED_OS`: optional but recommended for `--check` drift detection — bump `SHOW_EXPECTED_APK` after every BLUE build refresh so the dashboard flags stale devices
- `SHOW_KIOSK_VERSION`: expected `versionName` of the BLUE kiosk build (the kiosk *package* is shared across shows, but the version baked into each build is per-show, e.g. `1.0b`). Blank skips the check.
- `SHOW_SHEETS_URL`: Google Apps Script URL for the BLUE tracking sheet. Paste exactly:

  ```
  https://script.google.com/macros/s/AKfycbwF301VZqlntJlUhVVZK-6XFyVm7FAwMhXtwt7wlDPPhxQn6cfnGkOY2-0mSooAr9s/exec
  ```

  This is the Web App for the "Kagami Osaka - Blue Show Device tracker" workbook (tab: "Kagami Osaka - Blue Device status"). If you leave this blank, BLUE flash/provision will simply skip sheet updates — fine for a bench dry-run, not what you want for the real fleet.

Accept the offer to make `KAGAMI_BLUE` the active show. Commit `shows/KAGAMI_BLUE.conf` on `dev` and push so other operators inherit it via `./update.sh`.

---

## 2. KAGAMI_BLUE — Phase A: USB-bench precursor

Every functional BLUE device goes through this before Phase B (fleet flow) starts. Two groups:

- **~180 HK devices** arrive at ML2 1.4.1 (already past OOBE) but were never provisioned by this toolkit — fleet key not yet trusted, no WiFi ADB enabled. They need the operator "Allow USB debugging" tap on first connect from each laptop. Functional triage happens here: a unit that won't boot or won't respond over ADB gets set aside and reported to the supervisor; don't burn bench time fighting hardware.
- **24 PGH-flashed devices** were provisioned for `KAGAMI` (Red) in Pittsburgh. The fleet key is already trusted (no Allow tap needed) but the stored WiFi credentials point at the Red SSID, so they need a USB-bench pass to swap to `KAGAMI-Blue` and update settings to the BLUE conf.

The same script run (`./ml_provision.sh --deploy` if builds are ready, else `./ml_provision.sh`) handles both groups — `ml_provision.sh` is idempotent and doesn't care whether a device was previously provisioned.

**Per-device steps live in [`playbook_blue_osaka.html`](playbook_blue_osaka.html) (EN/JA).** The high-level shape: USB-C connect → Allow dialog if it appears → `./ml_provision.sh` (with `--deploy` when builds are present) → confirm show banner shows `KAGAMI_BLUE` → press Enter → complete the manual-headset checklist → press Enter at the gate → device's WiFi ADB enabled, IP printed, USB disconnect.

### Throughput

~5 minutes per functional device including the Allow tap and the manual-headset checklist gate. **8 stations** (4 operators × 2 laptops) × ~5 min/device ≈ **~2.5 hours** for ~200 functional devices through Phase A. Triage of dead-on-arrival HK units adds variable overhead — pull them aside fast and keep the line moving.

The HK ~180 are the slower group because of the unavoidable Allow tap on every first (laptop, device) pair. Once authorized, the fleet key covers all other operator laptops for that device.

---

## 3. KAGAMI (Red) — Phase B: fleet flow (180 devices)

The 180 RED devices arrive fully provisioned for `KAGAMI` (settings applied, on the Pittsburgh `KAGAMI` SSID config). They do **not** need a USB bench unless drift is detected. The on-site work is a fleet APK deploy + per-device SSD asset load.

### Setup
- Connect the KAGAMI laptop to the venue's `KAGAMI` SSID.
- Confirm `shows/KAGAMI.conf` matches the venue. If the venue's `KAGAMI` SSID differs from Pittsburgh's, this is **not** a simple network swap — every device's stored WiFi credentials point at the Pittsburgh SSID and would need a USB-bench WiFi update like BLUE Phase A. Assume same SSID unless confirmed otherwise on the day.

**Supervisor — fleet preparation (network ops over WiFi ADB, run once; not an operator task):**
1. Power on the fleet (operators can do the physical power-on).
2. `./utilities/ml_scan.sh` → build `devices/KAGAMI.txt`; confirm the device count.
3. `./ml_provision.sh --fleet --check` for drift; `./ml_status.sh --fix` to remediate.
4. `./ml_deploy.sh deploy` → install show APK + kiosk APK + reboot.
5. Dashboard sweep (`./ml_status.sh --json > status/latest.json` → `fleet_dashboard.html`) to confirm fleet health.
6. `./ml_deploy.sh shutdown` to power the fleet down for asset load.
7. Prepare and distribute the SSDs; hand the powered-off, deployed devices off to operators.

**Operators — per-device SSD asset load:** the operator job is *only* this loop, documented in [`playbook_red_osaka.html`](playbook_red_osaka.html) (EN/JA). Each operator carries multiple SSDs and runs several devices in parallel: attach SSD to a powered-off device → power on → glance into the headset to confirm the copy started (folders + tones, not the boot sound) → start the next SSD while it copies → on the finish tones/splash, remove the SSD → leave the device powered on and racked → reuse the freed SSD on the next device. Throughput scales with SSD count. Operators do **not** run the fleet scripts — that's the supervisor chain above.

**Final verify (supervisor):** re-run `./ml_status.sh --json`, re-sweep the dashboard, confirm the data-dir rows are clean (assets landed, no "data missing" flags), and make the go / no-go call.

> **Phase B is iteration-friendly.** BLUE and RED builds will be refreshed multiple times as the shows are finalized. The supervisor's deploy workflow is the same each time: drop new APKs into `builds/`, re-run `./ml_deploy.sh deploy`, re-sweep the dashboard. Bump `SHOW_EXPECTED_APK` in the show conf after each refresh so the dashboard flags any device that missed it.

---

## 4. Cross-show reconfigure (post-Phase-A movements)

The bulk cross-show move — 24 PGH-flashed devices originally provisioned for RED needing to run BLUE — is handled in BLUE Phase A above (the same `./ml_provision.sh --deploy` pass re-points them). This section covers the smaller case: a single device gets misassigned after Phase A is done and needs to be moved.

### Procedure

1. Move the device to the laptop for the **target** show.
2. USB connect → operator taps "Allow USB debugging" if this is the first time this laptop has seen this device.
3. With the target show active on the laptop (`./ml_show.sh use <target_show>` already in effect):

   ```bash
   ./ml_provision.sh --deploy
   ```

   This re-applies settings, swaps WiFi to the target show's SSID, and installs the target show's APK in one shot.
4. Remove the device from the **source** show's `devices/<source>.txt` and add it to the **target** show's `devices/<target>.txt` (or re-run `./utilities/ml_scan.sh` once it's on the target SSID).
5. Attach SSD with the target show's asset payload (timing trick from Phase B applies here too: SSD on, then power on).
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

- **BLUE SSID/password TBD** — working name `KAGAMI-Blue` / `KAGAmius` is what the playbooks default to; supervisor confirms (or overrides) at print time. The values land in `shows/KAGAMI_BLUE.conf` via `./ml_show.sh init`, so a wrong default just means the operator types over it at init time — not a deploy-time risk, but worth nailing down before laptops are handed out.
- **BLUE show APK / kiosk / data dir / expected versions TBD** — these are expected to iterate. Tooling absorbs this cleanly (drop new APK in `builds/` → re-run deploy); the only thing that can drift is `SHOW_EXPECTED_APK` in the conf, which supervisors should bump after each build refresh so the dashboard surfaces stale devices.
- **`shows/KAGAMI.conf` SSID match** — if the venue's `KAGAMI` SSID differs from Pittsburgh's, the 180 RED need a USB-bench WiFi update like BLUE Phase A. Confirm SSID parity on day 1.
- **Fleet-key auth tap** — manual, per (laptop, device) pair, unavoidable on user build 1.4.1. The 180 HK in BLUE Phase A are the bulk of these taps; the 24 PGH-Blue and the 180 RED won't need them (fleet key already trusted from PGH).
- **Update gate vs `dev` branch** — every main script hard-stops if local HEAD differs from `origin/main`. On-site work should run from `main`. If hot-fixes are made on site, merge `dev` → `main`, tag, and re-run `./update.sh` on every operator laptop before continuing.
