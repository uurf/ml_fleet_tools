# Proposal: Live controls for the Fleet Dashboard

**Status:** Feasibility / go–no-go — _not started_
**Issue:** [uurf/ml_fleet_tools#41](https://github.com/uurf/ml_fleet_tools/issues/41)
**Date:** 2026-05-22

This is a decision brief for the technical producers: deciding **whether the
investment is worth it**, before any implementation. The short version: all
three requests are feasible, but they share one prerequisite that turns the
dashboard from a static file into a small local app. That prerequisite is the
real decision.

---

## What's being asked

1. The dashboard auto-loads `asset_serial_list.csv` from the repo, and only
   prompts for a CSV file if it can't be found.
2. Dashboard buttons fire the existing scripts:
   `utilities/ml_scan.sh`, `ml_deploy.sh connect`,
   `ml_status.sh --json > status/latest.json`.
3. Dashboard buttons fire `ml_deploy.sh reboot` and `ml_deploy.sh shutdown`.

## The core constraint

`fleet_dashboard.html` is today a **static `file://` page with no backend.**
Data only enters through the browser's file picker (`Load JSON` / `Load CSV`)
or drag-and-drop, read via `FileReader`. There is no `fetch()`, no server, no
shell access.

The browser security sandbox makes a static page **physically unable** to:

- read a file by path — `fetch('file:///…/asset_serial_list.csv')` is blocked
  in every modern browser, so #1 cannot auto-load;
- run a shell command — there is no browser API to launch a script, so #2 and
  #3 are impossible.

| Ask | Static page (today) | With a local server |
|-----|--------------------|---------------------|
| 1. Auto-load asset CSV | ❌ can't read by path | ✅ trivial |
| 2. Fire scan / connect / status | ❌ impossible | ✅ |
| 3. Fire reboot / shutdown | ❌ impossible | ✅ (subcommands already exist) |

## The decision: add a local loopback server, yes or no?

Everything hinges on this single fork. If we add a tiny web server in front of
the dashboard, all three become feasible. If we don't, we are capped at the
manual flow we have today (the only static-only win would be Chrome's File
System Access API to *remember* a CSV handle — Chromium-only, still needs a
one-time grant, does nothing for #2/#3).

**What the server would be:** a small **standard-library Python server** (no
pip dependencies — matching the project's existing "no build system, Python
`urllib` only" approach), launched by e.g. `./ml_dashboard.sh`, bound to
`127.0.0.1` only, exposing:

- `GET  /api/asset-list` → returns the CSV (404 → page falls back to the
  existing Load-CSV prompt) — covers #1
- `GET  /api/status/latest` → serves `status/latest.json` for auto-refresh
- `POST /api/{scan,connect,status,reboot,shutdown}` → runs the scripts — #2/#3

Rough size: **~150–250 lines** for the server. That is *not* where the effort
or risk lives.

## Where the real effort/risk lives

The server is easy. These four integration realities are the actual work:

1. **Update gate.** `ml_status.sh` / `ml_deploy.sh` hard-stop when local `HEAD`
   differs from `origin/main`. Fine for operators on a tagged `main`; on `dev`
   the server must pass `ML_DEV_TEST=1`.
2. **Interactive confirmation has no TTY.** Destructive entry points call
   `show_confirm`, which makes the operator *type the show id* in a terminal. A
   web button has no terminal, so it would block. We'd pass
   `ML_SHOW_CONFIRMED=1` and make **the dashboard UI the confirmation surface** —
   which for reboot/shutdown is exactly what we want anyway (a "type the show id
   to confirm" modal so a stray click can't power-cycle the fleet).
3. **Long, parallel jobs.** A status sweep hits ~200 devices; a scan walks the
   subnet. Endpoints can't be synchronous requests that hang — they must run
   async with the page polling for completion, plus a guard so two sweeps can't
   overlap.
4. **Security.** A localhost service that can `reboot`/`shutdown` the fleet is a
   remote-execution surface. It must bind to `127.0.0.1` only (never `0.0.0.0`),
   especially on show-day shared WiFi.

## Verified facts

- `ml_deploy.sh` already has `reboot` (`ml_deploy.sh:642`) and `shutdown`
  (`ml_deploy.sh:646`) subcommands — #3 needs no new device-side work.
- The dashboard already has manual `Load CSV` / `Load JSON` + drag-drop.

## Suggested phasing if approved

- **Phase 1 — low risk, high value.** Stand up the server; wire only the *safe*
  controls: CSV auto-load (#1), "Refresh status" (`status --json` → reload),
  "Scan", "Connect". None are destructive.
- **Phase 2 — destructive, guarded.** `reboot` / `shutdown` behind a confirm
  modal + **device scoping** (selected rows vs. whole fleet) + the show-id gate
  surfaced in the UI.

## Recommendation

The capability is genuinely useful on show day at fleet scale, and the build is
modest. The honest cost is not the ~200-line server — it's owning a local
control surface that can power-cycle the fleet (security + confirmation UX), and
the async/long-job plumbing. If we proceed, **Phase 1 alone** delivers most of
the day-to-day value (auto-CSV + one-click refresh + scan/connect) at a fraction
of the risk; treat Phase 2 (reboot/shutdown) as a separate, explicitly-gated
decision.

**Decision needed:**
1. Add the loopback server at all? (yes / no / Phase 1 only)
2. If yes, scope of reboot/shutdown: selected devices, whole fleet, or both.
