# KAGAMI Toolkit — Pre-Merge Device Test Plan

On-device validation of the changes currently on `dev` before they are
PR'd to `main`. Run this on a real ML2 device (and the test laptop)
with the `dev` branch checked out.

## What this validates

| Commit | Change | Tested in |
|---|---|---|
| multi-show support | per-show config, `ml_show.sh`, show-id confirm gate, resolver wired into every script | A, B |
| Bluetooth must be ON | provision sets BT on; status/dashboard flag BT off; `--fix` enables BT | C, D |
| chain fixes | manual-steps pause restored (`</dev/tty` + `sh()` `</dev/null`); WiFi enable+retry+90s | B |
| `ML_DEV_TEST` escape hatch | update gate bypass for dev testing | all |

## Prerequisites

```bash
git checkout dev && git pull            # dev branch, current
./ml_show.sh use KAGAMI                  # pin the show (ml_show.sh has no update gate)
./ml_show.sh                             # expect: Active show: KAGAMI
```

**The update gate.** On `dev`, local HEAD differs from `origin/main`, so
every pipeline script will hard-stop with "Toolkit is out of date"
unless bypassed. Prefix **every** command below with `ML_DEV_TEST=1`.
A yellow `⚠ ML_DEV_TEST set — update gate bypassed` line is expected and
correct on `dev`. Remove `ML_DEV_TEST` from the environment for any
production run so the gate re-arms.

---

## A — Multi-show resolution (no device required)

> **Reading this table:** type only the text inside the `code` box in the
> Command column, exactly, then Enter. The Pass-criteria column is what
> you should *see* — never type it.

| Step | Command | Pass criteria |
|---|---|---|
| A1 | `./ml_show.sh` | Reports `Active show: KAGAMI` (set in Setup above). |
| A2 | `ML_DEV_TEST=1 ./ml_status.sh` | (no device attached) passes gate, prints `Show: KAGAMI` banner, then `No devices online` — does NOT stop at the update gate |
| A3 | `./ml_show.sh init` | Answer the prompts with a throwaway id; it writes `shows/<id>.conf`. Then run `./ml_show.sh use KAGAMI` to switch back. |
| A4 | Open `docs/setup_checklist.html` and `docs/flash_checklist.html` | Both reference the "Select the show" / "Active show is set" step and the **type the show id** confirm — and that wording matches what the scripts actually do in A2 and B1. |

---

## B — Full flash → provision → deploy chain (real device)

Run `ML_DEV_TEST=1 ./ml_os_flash.sh` and verify, in order:

| # | Watch for | Pass criteria |
|---|---|---|
| B1 | Pre-flash confirm | Prompts `Type the show id ('KAGAMI') to continue:`. A wrong id aborts; `KAGAMI` proceeds. |
| B2 | Chain hand-off | Provision and deploy do **not** re-prompt for the show (inherited confirmation). |
| B3 | WiFi section in provision | Device connects to KAGAMI (not "Auto-connect failed"). Note whether `svc wifi enable` succeeded or errored on the device. |
| B4 | Manual-steps gate | Checklist prints AND the script **waits** at "Press Enter when manual steps are complete". Complete the headset Device Auth + manual settings, then press Enter. **This is the key regression — confirm it actually blocks.** |
| B5 | Deploy timing | APK install runs only AFTER you press Enter. Kiosk set as home app. |
| B6 | End state | Device is on KAGAMI WiFi and reachable at its IP at the end of the chain. |

---

## C — Status + dashboard, Bluetooth inverted (provisioned device online)

| Step | Command | Pass criteria |
|---|---|---|
| C1 | `ML_DEV_TEST=1 ./ml_status.sh` | BT column = ✓ when Bluetooth is **on**. A device with BT off fails the sweep. |
| C2 | `ML_DEV_TEST=1 ./ml_status.sh --json > status/latest.json`, open `fleet_dashboard.html`, Load JSON | BT-on = pass; BT-off is the flagged issue (column header reads "BT on"). |

---

## D — Bluetooth auto-fix (unverified path)

| Step | Command | Pass criteria |
|---|---|---|
| D1 | Manually turn BT off on a device, then `ML_DEV_TEST=1 ./ml_status.sh --fix` | `svc bluetooth enable` runs and BT comes back on; re-run shows the device passing. |

---

## Highest-risk items (could not be verified without hardware)

- **B4** — the manual-steps pause actually blocking in a real chain (core regression fix).
- **B3 / D** — `svc wifi enable` and `svc bluetooth enable` on the ML2 1.4.1 *user* build. Both are best-effort (`|| true`); if either no-ops, note it — that part likely needs a device-specific command.
- **B1–B2** — show-id confirm and its inheritance down the chain.

## After the test

- Confirm the printed checklists match reality: `docs/flash_checklist.html` (typed show-id confirm + active-show precondition) and `docs/setup_checklist.html` (one-time `./ml_show.sh use KAGAMI`). `docs/headset_checklist.html` is unaffected — no change expected.
- All sections pass → the `dev` → `main` PR is justified.
- Record any device-specific command corrections (esp. B3/D) before merging.
- Ensure `ML_DEV_TEST` is unset on production/operator machines so the
  update gate is active for real runs.
