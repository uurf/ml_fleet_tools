# KAGAMI Field Operations — Tin Drum

### On-site fleet monitoring & updates (show-day runbook)

This is the runbook for the **live show**, not the bench. It assumes the
fleet is already flashed, provisioned, and deployed (see PROVISIONING.md
and DEPLOYMENT.md). Here the job is: keep ~200 headsets per show in a
known-good state during a run, across **two concurrent shows** (e.g.
`KAGAMI` and a second show), and push the occasional field update.

Different person, place, and cadence than provisioning — this is done
repeatedly over WiFi against the running fleet.

---

## 0 — One-time: pin this machine to a show

Each operator/machine runs **one** show. Set it once:

```bash
./ml_show.sh                 # show the active show + what's available
./ml_show.sh use KAGAMI      # pin this machine to the KAGAMI show
```

Standing up a brand-new show on site (the entire setup):

```bash
./ml_show.sh init            # prompts for WiFi, package, expected versions
```

Every command below operates on the **active show's** fleet
(`devices/<show>.txt`) and config. Status output and banners print the
resolved show — glance at it before acting.

---

## 1 — Health sweep

```bash
./ml_status.sh               # full pass/fail table for the active show
```

Each device is checked for OS, show APK, kiosk app, battery, and the
settings that drift (stay-awake, WiFi, Bluetooth-off, brightness,
dev/USB, auto-update-off). The trailing summary is the at-a-glance
"is the fleet OK" number.

Triage and remediate:

```bash
./ml_status.sh --failures    # only devices with a problem
./ml_status.sh --fix         # auto-fix the fixable drift, then re-run
```

`--fix` repairs stay-awake, Bluetooth, and brightness. Display/dimming
and Compute-Pack-Standby are headset-manual (see PROVISIONING.md) and
will keep showing as manual items — that's expected.

> Compliance baselines (`SHOW_EXPECTED_APK` / `SHOW_EXPECTED_OS` in the
> show config, or `--expected-apk` / `--expected-os`) make a device with
> the wrong build fail the sweep instead of passing silently — set them
> per show so a stale headset is visible.

**Full `ml_status.sh` flag + env-var dictionary:** see
**PROVISIONING.md → ml_status.sh flags** (single source of truth).

---

## 2 — Visual dashboard

`fleet_dashboard.html` does not read files on its own. Generate the JSON,
then load it in the page:

```bash
./ml_status.sh --json > status/latest.json
```

Open `fleet_dashboard.html`, click **Load JSON** (or drag the file onto
the page). Re-run the command and reload to refresh. The banner is
written to stderr, so the redirected file stays valid JSON even though
you still see the show name in the terminal.

For a recurring watch, re-run the sweep on an interval and reload the
dashboard — there is no daemon; it's pull, on demand.

---

## 3 — Field APK update over WiFi

When a new show build needs to go out mid-run:

```bash
./ml_deploy.sh deploy            # connect all, pick APK(s), install, set kiosk home
./ml_deploy.sh -d <ip> deploy    # one device
```

`deploy` prints the show banner and waits at a confirm prompt (Enter to
proceed, `S` to switch to another configured show) before it installs
to the whole fleet. After updating, bump `SHOW_EXPECTED_APK` in
`shows/<id>.conf` so the status sweep flags any device that missed the
update.

---

## 4 — Two concurrent shows

The two shows are independent fleets with different WiFi and different
builds, run from the same codebase:

- Each operator machine is pinned to one show via `./ml_show.sh use`.
- Fleet lists are per-show: `devices/<show>.txt` (rebuild on site with
  `./utilities/ml_scan.sh`, which writes the active show's file).
- `shows/<show>.conf` carries that show's SSID/password/package and
  expected versions. `shows/KAGAMI.conf` mirrors the original values.
- A wrong-show action is caught by the show-confirm gate at
  flash/provision/deploy (banner + Enter-to-proceed / S-to-switch);
  status/dashboard are read-only and just print the resolved show.

To work the other show from the same machine: `./ml_show.sh use <other>`
and re-run. Nothing else changes.

---

## Out of scope

The Google Sheet name in `apps_script/Code.gs` is still single-show
(server-side, deployed separately). Per-show sheet routing is a separate
follow-up and is intentionally not handled here.

---

## Summary

| Task | Command | Notes |
|---|---|---|
| Pin machine to a show | `./ml_show.sh use <id>` | One-time per machine |
| New show on site | `./ml_show.sh init` | Prompts; no bash editing |
| Health sweep | `./ml_status.sh` | Active show's fleet |
| Triage only failures | `./ml_status.sh --failures` | |
| Auto-fix drift | `./ml_status.sh --fix` | Stay-awake/BT/brightness |
| Feed dashboard | `./ml_status.sh --json > status/latest.json` | Then Load JSON |
| Field APK update | `./ml_deploy.sh deploy` | Typed show-id confirm |
| Nightly shutdown | `./ml_deploy.sh shutdown` | Powers off all online devices — run end-of-day |
| Rebuild fleet list | `./utilities/ml_scan.sh` | Writes `devices/<show>.txt` |
| Full status flags | see PROVISIONING.md | Single source of truth |
