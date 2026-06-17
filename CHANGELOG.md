# Changelog
### ML Fleet Toolkit — Tin Drum / KAGAMI

All notable changes to this project will be documented here.
Format: [Semantic Versioning](https://semver.org) — `major.minor.patch`

- **Major** — breaking changes, new show configuration
- **Minor** — new features, new scripts
- **Patch** — bug fixes, wording changes, documentation updates

---

## [v1.2.1] — 2026-06-17 — Fix v1.2.0 regression: deploy aborted silently on a failed install

### Fixed
- **`ml_deploy.sh` no longer dies silently mid-deploy.** v1.2.0's new failure-surfacing code used `why=$(grep … | tail -1)` and `do_install` used unguarded `out=$(adb … 2>&1)` / `pkg=$(… | grep | …)` captures. Under the script's `set -euo pipefail`, `grep` returning non-zero on a no-match (surfaced by `pipefail`) made those `x=$(failing pipeline)` assignments abort the entire run — so a failed kiosk install dropped straight back to the prompt with no `✗`, no reason, and no "Done" line. Every such capture is now `|| true`-guarded and status is derived from the `Success` text, not exit codes. Verified the deploy survives: fallback-reinstall success, total install failure, and an empty job log all complete cleanly now.

---

## [v1.2.0] — 2026-06-17 — Foreign-show app removal + resilient APK install

### Added
- **`SHOW_REMOVE_PACKAGES` config field** — space-separated packages from *other* shows to uninstall while provisioning this show. `KAGAMI_BLUE.conf` removes the RED show app `com.tindrum.kagamu`; `KAGAMI.conf` removes the BLUE app `com.tindrum.kagami.blue` (symmetric). Seeds `ml_provision.sh`'s `REMOVE_PACKAGES`, so it's gated to the provision pass and never runs under `--check`. `--check` now also lists these explicit packages. Config-driven — onboarding a show stays a conf edit.

### Fixed
- **`ml_deploy.sh` APK install survives a signature mismatch.** `do_install` previously did a bare `adb install -r -g`, which fails when the on-device package was signed with a different key — exactly what happened deploying `kiosk-kagami-blue.apk` over a `com.tindrum.kiosk` written with a non-fleet key. It now tries `-r -d -g` (the `-d` also clears a version-downgrade in place), and **only on a signature/downgrade conflict** uninstalls the offending package (parsed from adb's error) and reinstalls. A fleet-key app still updates in place with no uninstall.
- **Failed deploys show the real reason.** The per-device `✗` line printed `tail -1` of the log, which is usually a trailing blank line — so failures rendered as `✗ <serial> —` with no message. It now surfaces the actual `Failure […]` / `INSTALL_FAILED…` / `adb:` line (both result loops in `ml_deploy.sh`).

---

## [v1.1.4] — 2026-06-17 — install.sh: persist Homebrew PATH to all profiles + honest bash check

### Fixed
- **`install.sh` now persists the Homebrew `shellenv` line to every profile a macOS shell might read** (`.zprofile`, `.zshrc`, `.bash_profile`, `.bashrc`), not just `.zprofile`. `.zprofile` is read by *login* zsh shells only, so operators whose terminal runs a non-login interactive shell (or bash) still resolved `/bin/bash` 3.2 after install.
- **The post-install bash check no longer lies.** It previously probed `bash` in install.sh's own process — which had already `eval`'d `brew shellenv`, so it always reported "bash 5.x in use" even when the operator's actual terminals would still get 3.2 (symptom: script reports 5 but `bash --version` says 3.2). It now probes a fresh `zsh -lic` login shell, reflecting what a new terminal will really resolve, and prints the exact `eval "$(brew shellenv)"` recovery line if not.

### Operator note
If you already ran the old `install.sh` and `bash --version` still shows 3.2: run `eval "$(/opt/homebrew/bin/brew shellenv)"` in your terminal (or re-run `./install.sh` and open a new terminal).

---

## [v1.1.3] — 2026-06-17 — Hard-stop scripts on bash 3.2 + reliable Homebrew bash on PATH

### Fixed
- **Scripts no longer fail cryptically under macOS's stock bash 3.2.** The `ml_*` scripts use a `#!/usr/bin/env bash` shebang, so they silently ran under `/bin/bash` (3.2) whenever Homebrew bash wasn't first on PATH — surfacing as `mapfile: command not found` deep inside `ml_deploy.sh` (and anywhere else relying on bash 4+ builtins). New `lib/require_bash5.sh` is sourced first by every script and hard-stops with an actionable message (open a new terminal / `exec zsh -l`; run `./script`, not `sh script`) before any 3.2-incompatible code runs.
- **`install.sh` now actually puts Homebrew bash on PATH — for the current shell and new terminals.** Previously `eval "$(brew shellenv)"` ran only on a fresh Homebrew install (never the "already installed" path), and the change never reached the running terminal, so the very next `./ml_deploy.sh` in the same window hit bash 3.2. It now evals `shellenv` in both branches and appends it idempotently to `~/.zprofile`.
- **`install.sh` bash check is no longer cosmetic.** It previously only checked that `/opt/homebrew/bin/bash` existed and printed a green tick even when 3.2 was what actually ran. It now probes the resolved `bash`'s major version and, if it's still < 5, tells the operator to open a new terminal.

### Changed
- The bash-5 guard is wired into `ml_os_flash.sh`, `ml_provision.sh`, `ml_deploy.sh`, `ml_status.sh`, `ml_show.sh`, and `update.sh`.

---

## [v1.1.2] — 2026-06-10 — Operator-only playbook re-scope + translator JA finalized

### Changed
- **RED & BLUE operator playbooks re-scoped to operator-only.** Supervisor fleet operations (network scan, `--fleet --check` drift, `ml_deploy.sh deploy`, dashboard sweep, fleet shutdown, final verify) were cut from the operator playbooks and live in `docs/onsite_osaka.md`. Operator playbooks now cover only the physical, large-parallel hands-on work: RED is the per-device SSD asset-load loop; BLUE is Phase A USB-bench provisioning + the same SSD loop. Rationale: operators do physical work, supervisors run the network/fleet scripts — the two were previously mixed in one doc.
- **SSD asset-load loop corrected and shared between RED and BLUE.** Distinguishes the device **boot sound** from the show APK's **copy tones** (起動音 vs 開始音/終了音); the copy is confirmed by glancing into the headset (data folders in the display), not by wearing it continuously; operators run several devices in parallel with multiple SSDs; finished devices are left powered on and racked. Dropped the device-hours time estimate. Closing line softened from "fleet is show-ready" to "Assets loaded — handed off to supervisor" (readiness is the supervisor's go/no-go call).
- **BLUE Phase A: manual headset settings inlined.** The manual-headset checklist gate step now spells out the six settings bilingually (Battery → Compute Pack Standby: Off; Display Override: Off; Global / Segmented / Maximum Dimming; System → OS Updater: Never) instead of pointing operators at the EN-only `headset_checklist.html`. Added a follow-on step to record the completed settings in the *Kagami Osaka – Device tracker* sheet.

### Documentation
- **Translator (Maria Takeuchi) JA revisions applied** to `docs/setup_checklist.html` and the retained sections of `docs/playbook_blue_osaka.html` (RED was applied earlier this cycle), completing the EN/JA roundtrip for the operator docs. House-style term decisions: デバイス (not 機), ラップトップ (not ノートPC), チームリーダー, 修正 (not 修復), 開始音/終了音; polite です・ます detail text with terse dictionary-form labels.
- **"Translation draft — please review" banners removed** from `setup_checklist.html` and both playbooks now that the Japanese has been translator-reviewed (footer "Translation draft" tags dropped too).
- **`docs/onsite_osaka.md`:** RED §3 reworded so the scan → check → deploy → dashboard → shutdown chain reads as an explicit **supervisor** sequence; added a parallel **BLUE Phase B fleet-flow** supervisor sequence (`ML_SHOW=KAGAMI_BLUE`); added a **supervisor prerequisite** to share the *Device tracker* sheet with each operator's Google account as Editor (per-account, not "anyone with the link") before Phase A — the playbook link is only a deep-link and does not grant access.
- **BLUE §0 trimmed** to BLUE-specific setup; the generic *toolkit installed* / *fleet ADB key* steps (duplicated verbatim in `setup_checklist.html`, which §0 already references) were removed.

---

## [v1.1.1] — 2026-06-04 — Inline fleet-key install + bilingual setup checklist + ADB-key cleanup

### Added
- **`install.sh` now waits for the fleet key inline.** On a fresh machine the installer pauses after cloning, prompts the operator to drop `adbkey_kagami_fleet` into `authorized_keys/`, waits for confirmation, activates it, and only then reports `Installation complete!`. It reads from `/dev/tty` so the prompt works even under the `curl … | bash` one-liner (where stdin is the piped script, not the keyboard). Replaces the old "installer reports complete, then separately place the key and run it again" two-pass flow.
- **Japanese translation column on `docs/setup_checklist.html`.** The machine-setup checklist is now bilingual EN | JA (two-column CSS grid), matching the Osaka operator playbooks. Carries the same "translation draft — please review" banner pending Tin Drum bilingual QC.

### Changed
- **`ml_provision.sh`: ADB-key injection disabled.** The block that pushed `authorized_keys/*` into the device's `/data/misc/adb/adb_keys` is commented out. It is a no-op on the production ML2 1.4.1 *user* build — the secure OS ignores pre-seeded `adb_keys` — and its "All authorized keys pushed" output falsely implied ADB auth was handled. What actually authorizes the fleet is the shared fleet key plus a single in-headset "Allow" tap per device. Re-enable only for userdebug/non-secure builds. (`ml_os_flash.sh`'s equivalent injection is intentionally left as-is — flash is the rarely-run, problem-device-only path.)
- **`install.sh` internals + honest completion.** De-duplicated key activation (was copy-pasted across two branches) into `install_fleet_key()`, added `fleet_key_matches()` for clean "already configured" detection on re-run, and made the final banner/Next-steps reflect whether the key actually installed (if not, it leads with the remaining fleet-key task instead of a flat "complete").
- **`docs/setup_checklist.html`: single-run flow + optional OS-image section.** Replaced the "copy key / run installer again" steps with "add the fleet key when prompted" plus a fallback step for operators who don't yet have the key. Marked the **OS image** section *Optional* (EN/JA badge + note) — it's only needed to flash a device to a clean factory MLOS state, which is occasional and for specific problem devices.

### Documentation
- **`authorized_keys/README.txt` rewritten around the fleet-key model.** Describes the shared `adbkey_kagami_fleet` as the sole working mechanism (every laptop installs it as `~/.android/adbkey` → one identity → one "Allow" tap per device, *not* per laptop). Drops the obsolete "commit and push your machine's `.pub`" instructions; the per-machine `.pub` files are inert on the production build (gitignored, no effect) and now documented as such.
- `install.sh`: "Action required" message names `adbkey_kagami_fleet` (was `adbkey`).

---

## [v1.1.0] — 2026-06-01 — Per-show Sheets integration + Osaka operator playbooks

### Added
- **Per-show Google Sheets integration.** `SHOW_SHEETS_URL` in `shows/<id>.conf` now points the toolkit at each show's own bound Apps Script + tracking workbook (KAGAMI: `Kagami Osaka - Device tracker`; KAGAMI_BLUE: `Kagami Osaka - Blue Show Device tracker`). `ml_provision.sh` / `ml_os_flash.sh` `update_sheet()` reads `$SHOW_SHEETS_URL`; an empty value is a clean no-op (bench dry-runs / shows without a workbook). Replaces the previous single-URL constant in both scripts (one of which was stale and pointing at an archived deployment).
- **Osaka operator playbooks** — `docs/playbook_red_osaka.html` (180 RED devices, 9 sections, 33 steps) and `docs/playbook_blue_osaka.html` (~204 BLUE devices, Phase A USB-bench precursor + Phase B fleet flow, 37 steps). EN/JA side-by-side layout (CSS grid), printable A4 with page-break-aware CSS. SSD asset-transfer timing trick documented (attach SSD before power-on, listen for start/finish tones). Japanese pass is marked "translation draft — please review" pending Tin Drum bilingual staff QC.
- `apps_script/Code.gs`: top-level `SHEET_TAB_NAME` const + header block documenting the per-workbook bound-deployment procedure. Pasting the same canonical script into each workbook's editor + editing one line is now the supported pattern for adding a new show's sheet.
- `ml_show.sh init`: prompts for the show's `SHOW_SHEETS_URL` so on-site setup writes it straight into `shows/<id>.conf`.
- `tests/test_sheet_integration.sh`: device-free regression suite (11 tests) covering per-show URL plumbing, opt-out behavior, the `ml_show.sh init` prompt flow, `Code.gs` parameterization, and a guard against stale `AKfycb…` URLs reappearing.

### Changed
- `ml_status.sh --csv`: expanded column set. Adds `hw_serial`, `kiosk_version`, `kiosk_installed`, `charging`, `disk_used_pct`, `hand_nav_on`, `data_missing_count`, `data_extra_count` so the CSV mirrors what the table, JSON, and dashboard expose rather than reporting a partial view.
- `docs/flash_checklist.html`, `docs/setup_checklist.html`, `docs/headset_checklist.html`: legibility pass. Body 13→15px, step labels 13→15.5px, section headers 9→11px, code 10.5→12.5px, checkbox 15×15→18×18, max-width 640→720px, print `@page` margin 1.2cm→0.7cm. Content unchanged.
- `docs/onsite_osaka.md`: rewritten as a supervisor-grade reference that delegates per-device steps to the new playbooks. Fleet counts corrected — 180 RED firm (80 per showtime × 2 + 20 spares) + ~204 BLUE target (= 24 PGH-flashed + ~180 HK, less DOA triage). BLUE `SHOW_SHEETS_URL` paste-in text added inline so the operator running `./ml_show.sh init` for `KAGAMI_BLUE` has it ready.

### Fixed
- `ml_deploy.sh`: shebang restored to `#!/usr/bin/env bash` (was `#!/opt/homebrew/bin/bash`, which broke on Intel Macs where Homebrew installs to `/usr/local`). The same fix landed for the other scripts in v0.5.8 but `ml_deploy.sh` had regressed. Usage examples also de-KAGAMI-ified (no more hardcoded `com.tindrum.kagamu` / `/sdcard/KAGAMI/`).
- `ml_os_flash.sh`: post-flash manual-steps fallback (only reached when `ml_provision.sh` is missing) no longer hardcodes `builds/kagami.apk` / `/sdcard/KAGAMI/` paths; references the active show via `$SHOW_SSID` / `$ML_SHOW` instead.

### Documentation
- `README.md`, `PROVISIONING.md`, `DEPLOYMENT.md`, `FIELD_OPS.md`, `CLAUDE.md`, `TESTPLAN.md`, `docs/flash_checklist.html`, `docs/dashboard_controls_proposal.md`: consistency pass for the post-v1.0.0 state. Replaces stale "type the show id" prompt wording with the current Enter / `S`-to-switch behavior (the gate UX changed in v1.0.0 but several docs still described the old form). Replaces hardcoded `devices.txt` with per-show `devices/<show>.txt` (legacy file is still the read-only fallback). Replaces KAGAMI-hardcoded paths/packages with per-show `SHOW_*` references. Corrects the `ml_status.sh --fix` description (brightness uses `$SHOW_BRIGHTNESS`, not the old `50`). Removes the "per-show kiosk = open item" notes (landed in v1.0.0 as `SHOW_KIOSK_VERSION`). `CLAUDE.md` key files table extended with the new playbooks.

---

## [Unreleased]

_Work in progress on `dev` branch. Merge to `main` via pull request when ready to release._

(No unreleased changes since v1.1.2.)

---

## [v1.0.0] — 2026-05-22 — Fleet-health dashboard hardening + per-show kiosk identity

### Added
- `SHOW_KIOSK_VERSION` per-show config field. Kiosk *package* (`com.tindrum.kiosk`) is shared across shows, but the *versionName* baked into each build is per-show — `ml_status.sh` reads versionName via `dumpsys package` (the app label isn't readable over ADB), and `fleet_dashboard.html` flags a mis-loaded kiosk. KAGAMI ships `1.0`; per-show suffix (`1.0r` / `1.0b`) is a future config-only edit.
- Offline-device surfacing. `ml_status.sh` diffs the expected fleet list against actually-online devices and emits `online:false` stubs, so a device in `devices/<show>.txt` that's not reachable shows up as a red `OFFLINE` row instead of vanishing. The dashboard backfills device# from a localStorage last-seen `ip → hw_serial` cache.
- `ml_status.sh`: data-dir content classification. `/sdcard/$SHOW_DATA_DIR/` entries are partitioned into required (`SHOW_DATA_REQUIRED`, missing = trouble), optional (`SHOW_DATA_OPTIONAL`, absence is fine), and extraneous (anything else, e.g. pathological `data/data` recursion). Case-insensitive match — ML2 `/sdcard` resolves paths case-insensitively (`data == Data == DATA`), confirmed 2026-05-22.

### Changed
- `show_confirm`: gate UX. Was: operator types the show id to proceed. Now: prints the show banner, prompts `Press Enter to continue, or S for other available show configurations:`. Enter proceeds; `S` opens a numbered picker of the other configured shows (writes `.active_show`, exits cleanly so the operator re-runs the command). Inheritance via `ML_SHOW_CONFIRMED=1` unchanged — chained children stay silent.
- `fleet_dashboard.html`: scope clarified. Dashboard surfaces *trouble that affects the show* (wrong OS/APK/kiosk, data dir missing/extraneous, extra `com.tindrum.*` packages, `/sdcard` over `SHOW_DISK_WARN_PCT`, hand-nav off, offline). Drift/compliance (sleep, dev mode, USB debugging, brightness, BT) is no longer on the dashboard — that's `ml_provision.sh --check` / `ml_status.sh --fix` territory.

### Fixed
- `ml_provision.sh`: no longer uninstalls the kiosk. `com.tindrum.kiosk` is the toolkit's own home/launcher app, but it was listed in `REMOVE_PACKAGES` and so was uninstalled on **every** non-`--check` provision — including standalone fleet drift remediation, which has no deploy after it to reinstall it. `REMOVE_PACKAGES` is now empty and the kiosk data dir is dropped from `REMOVE_DIRS`; foreign-show scrub (`An Ark` / `The Life` / `Medusa` + `/sdcard/AnArk`) is unchanged.
- `ml_status.sh --fix`: brightness fix now also forces adaptive/auto-brightness off (`screen_brightness_mode 0`) before writing `screen_brightness`. Previously it wrote the value only, so with auto-brightness on ML2 recomputed it from ambient light and the device drifted back (field: 3 devices stuck at ~50% that `--fix` wouldn't correct). `--fix` now corrects this drift even though `screen_brightness_mode` isn't a displayed status column.

### Documentation
- `CLAUDE.md`: documented the CLI argument conventions (verb-dispatch vs single-purpose) and the default-scope rule (fleet-by-default vs single-device + `--fleet` opt-in).
- `docs/onsite_osaka.md`: on-site runbook for the two-fleet KAGAMI / KAGAMI_BLUE Osaka deployment at VS Umeda. Documents the Pittsburgh-202 land-and-verify flow and the Osaka-180 bench-op flow (BLUE), including the unavoidable per-(laptop, device) "Allow USB debugging" tap on the 1.4.1 user build.
- `asset_serial_list.csv`: synced from the Google tracking sheet (canonical on-site device#→serial inventory; ~half the fleet, rest in Osaka).
- ADB pre-auth docs corrected: `adb_keys` injection runs but doesn't actually suppress the dialog on the 1.4.1 user build. The shared fleet key (`authorized_keys/adbkey_kagami_fleet`) is what keeps the fleet usable across operators — one Allow tap per device authorizes the fleet key, then every operator laptop is trusted.

---

## [v0.7.2] — 2026-05-19 — Kiosk-as-home reboot fix and show-selection UX

### Fixed
- `ml_deploy.sh`: kiosk-as-home was silently lost after the post-install reboot (#36). `do_set_home` now (a) fails loudly if `com.tindrum.kiosk` isn't installed, (b) verifies the kiosk actually resolves as the HOME activity (ML2 has three competing HOME activities), retrying until PackageManager applies it, and (c) returns a real ✗ instead of a false ✓ — `adb shell` does not propagate the inner exit code on ML2. Deploy now settles ~10s after setting home so PackageManager flushes the preference to disk before the reboot races it.
- `lib/show_config.sh`: no longer dead-ends with "no show configured" when the choice is unambiguous. One configured show is auto-selected; with multiple, an interactive run shows a numbered picker and continues in-process (no separate `./ml_show.sh use` step). Non-interactive callers (`--json`, fleet workers) still hard-stop, keeping machine-readable output safe.

---

## [v0.6.6] — 2026-05-15 — Hand navigation fix and doc updates

### Fixed
- `ml_provision.sh`: Hand navigation now sets `enable_pinch_gesture_inputs` (system namespace) — the correct key for pinch-to-interact pointer navigation. Previous key (`enable_home_gesture_inputs`, secure) controls the fist-to-home gesture only and does not enable hand navigation.

### Changed
- `PROVISIONING.md`: Fixed Segmented Dimming direction (Off → On); added Global Dimming and Maximum Dimming slider steps; added `--fleet`, `--fleet --check`, `-d <ip>`, and `ml_scan.sh` to quick reference
- `DEPLOYMENT.md`: Phase 3 now describes `ml_ssd_copy.sh`; summary table adds fleet settings remediation row
- `README.md`: Fixed Segmented Dimming direction; added Global/Max Dimming steps; updated script table with `--fleet` and `ml_scan.sh`
- `CLAUDE.md`: Updated script listing; added ADB-settable settings section documenting correct hand navigation key

---

## [v0.6.5] — 2026-05-15 — Package name fix

### Fixed
- Corrected show app package name from `com.tindrum.kagami` → `com.tindrum.kagamu` in `ml_provision.sh`, `ml_deploy.sh`, `fleet_dashboard.html`, `CLAUDE.md`, and `README.md` (`ml_status.sh` was already correct)

---

## [v0.6.4] — 2026-05-15 — Fleet settings mode

### Added
- `ml_provision.sh --fleet` — applies all ADB-settable settings to every device in `devices.txt` in parallel; buffers per-device output, prints sequentially with pass/fail summary
- `ml_provision.sh --fleet --check` — read-only settings audit across entire fleet
- `ml_provision.sh -d <ip>` — target a specific WiFi-connected device by IP

---

## [v0.6.3] — 2026-05-15 — Hand navigation enforcement

### Added
- `ml_provision.sh`: Enforces hand navigation on (`enable_home_gesture_inputs = 1`) during provisioning; verified readable/writable via ADB on 1.4.1 user build

---

## [v0.6.2] — 2026-05-15 — ml_scan.sh fix

### Fixed
- `utilities/ml_scan.sh`: `devices.txt` now written to repo root instead of `utilities/`

---

## [v0.6.1] — 2026-05-15 — Shellcheck cleanup

### Fixed
- `ml_os_flash.sh`: `find | xargs -I{}` → `find -exec` (SC2038 — handles filenames with spaces)
- `ml_status.sh`, `utilities/ml_ssd_copy.sh`: `PIDS=($(…))` → `mapfile -t PIDS < <(…)` (SC2207 — word-splitting safe)

### Removed
- Dead variables: `WANT_STAY_AWAKE/WIFI/BT/DEV_MODE/USB_DEBUG/AUTO_UPDATE`, `WARN`, `s_bright`, `v` in `ml_status.sh`; `YELLOW` in `update.sh`; `TARGET_OS` in `ml_provision.sh`

### Added
- `utilities/ml_scan.sh` — scans local network for ML2 devices on port 5555, prompts to confirm, writes discovered IPs to `devices.txt`

---

## [v0.6.0] — 2026-05-15 — Deploy workflow validated end-to-end

### Fixed
- `ml_provision.sh`: Restored chain deploy — `--deploy` flag triggers APK install over USB immediately after provisioning; `ml_os_flash.sh` passes the flag when chaining
- `ml_provision.sh`: Deploy now runs over USB *before* `adb tcpip 5555` so the ADB connection is still authorized when APKs are installed
- `ml_provision.sh`: Operator pause added at manual steps checklist when `--deploy` is set — press Enter after completing headset steps to begin APK install
- `ml_provision.sh`: Replaced broken `stop adbd && start adbd` (via shell) with `adb tcpip 5555` (host-side) as the last USB command
- `ml_provision.sh`: All manual steps unified into `MANUAL_STEPS[]`, printed once at the end with consistent `→` delimiters
- `ml_provision.sh`: Removed `MagicLeapDimmer` service calls that don't work on 1.4.1 user build
- `ml_os_flash.sh`: `adb disconnect` before post-flash boot wait clears stale WiFi ADB sessions; `adb wait-for-device` pinned to `$SERIAL` to avoid "more than one device" error
- `ml_deploy.sh`: `cmd_deploy_all` exits cleanly with a warning when `builds/` has no APKs

### Added
- `CLAUDE.md`: Repo guidance for Claude Code sessions

---

## [v0.5.9] — 2026-05-08 — Device number mapping in dashboard

### Added
- `asset_serial_list.csv` — 200-device hardware serial → device number mapping
- `fleet_dashboard.html`: Load CSV button maps hw_serial to device number; dashboard now shows Device # and Serial columns; search by device number or serial; default sort by device number

### Changed
- `ml_status.sh`: Adds `hw_serial` (physical serial from `ro.serialno`) to per-device JSON output
- `apps_script/Code.gs`: `deploy_complete` action added — checks off kiosk, APK, and permissions columns and sets status to "Ready for asset loading"; manual-only columns (Compute Pack Standby, Display dimming, OS Updater) removed from `provision_complete` auto-check
- `docs/headset_checklist.html`: Added "Tracking sheet" section listing manual items to check off in the Google Sheet after headset steps

---

## [v0.5.8] — 2026-05-08 — Shebang fix, Intel Mac support, status improvements

### Added
- `ml_status.sh`: Tracks both Kagami and Kiosk APKs separately in JSON output and table; auto-connects all devices in `devices.txt` before collecting status
- `fleet_dashboard.html`: Separate Kagami and Kiosk columns in table, filter, and CSV export

### Fixed
- `ml_os_flash.sh`, `ml_provision.sh`, `update.sh`: Shebang changed from `#!/opt/homebrew/bin/bash` to `#!/usr/bin/env bash` — fixes execution on Intel Macs where Homebrew installs to `/usr/local`
- `install.sh`: Added Homebrew PATH setup for Intel Macs (was only handling Apple Silicon)
- `ml_status.sh`: OS version now read from `ro.build.version.lumin` (ML2-specific property) instead of `ro.build.version.release`; update-check output redirected to stderr so it doesn't pollute `--json` mode

---

## [v0.5.7] — 2026-05-07 — Checklist updates

### Changed
- `docs/flash_checklist.html`: Removed manual write-in fields (device #, case #, operator, serial) — captured by the script now; updated step wording
- `docs/headset_checklist.html`: Added Display Override step; added "Shut down device" step at end (hold Power, wait for fan to stop before casing)

---

## [v0.5.6] — 2026-05-07 — Chain deploy after provision

### Added
- `ml_deploy.sh`: `cmd_deploy_all` — non-interactive deploy that installs all APKs in `builds/`, sets kiosk as home app; triggered via `--all` flag
- `ml_provision.sh`: Chains to `ml_deploy.sh --all` at end of provisioning when called from `ml_os_flash.sh` (via `ML_CHAINED=1` env var)
- `apps_script/Code.gs`: `deploy_complete` action handler; updated column headers to match current tracking sheet layout; added Compute Pack Standby and Segmented Dimming columns

### Changed
- `ml_provision.sh`: Brightness target set to 12 (was 0)

---

## [v0.5.5] — 2026-05-07 — SSD copy utility

### Added
- `utilities/ml_ssd_copy.sh` — copies show data from a USB-C attached SSD to `/sdcard/[showName]/data` on all fleet devices; discovers `[showName]_data` directories on the SSD and prompts operator to select a show if multiple are present; single-show drives auto-confirm; supports `-d <ip>` for single device or `devices.txt` for full fleet; parallel copy with progress display

---

## [v0.5.4] — planned — Deploy workflow

- `ml_deploy.sh` tested and validated on site
- `ml_status.sh` validated against full fleet
- `fleet_dashboard.html` wired to live fleet data
- `devices.txt` populated with show-site static IPs

---

## [v0.5.2] — 2025-05-01 — Bug fixes

### Fixed
- `ml_os_flash.sh`: missing `SCRIPT_DIR` definition causing unbound variable error on startup
- `ml_provision.sh`: stray quote in USB dialog checklist causing unbound variable error

---

## [v0.5.1] — 2025-04-30 — Bug fix

### Fixed
- `ml_provision.sh`: missing `SCRIPT_DIR` definition causing unbound variable error on startup

---

## [v0.5.0] — 2025-04-30 — KAGAMI provisioning pipeline

Initial working release. Flash, provision, and sheet tracking validated end-to-end.

### Versioning roadmap
| Version | Milestone |
|---|---|
| `v0.5.x` | Bug fixes and doc updates during provisioning phase |
| `v0.6.0` | Deploy workflow tested and validated on site |
| `v1.0.0` | Full pipeline proven in production — KAGAMI opens |

### Added
- `ml_os_flash.sh` — OS flash via `flashall_amd.sh`; ADB key injection; OOBE bypass; auto-provisions after flash
- `ml_provision.sh` — full device configuration: developer mode, WiFi, battery, display, app permissions, remove old apps; `--check` and `--discover` modes
- `ml_deploy.sh` — parallel APK install, asset push, app launch/stop/restart, fleet shell commands
- `ml_status.sh` — parallel status collection; table, JSON, and CSV output; `--fix` mode
- `fleet_dashboard.html` — visual fleet dashboard fed by `ml_status.sh --json`
- `install.sh` — one-command environment setup; Homebrew, adb/fastboot, fleet ADB key
- `update.sh` — pull latest from `origin/main`; show current and new version tags
- Google Sheets integration — `flash_start`, `flash_complete`, `flash_failed`, `provision_start`, `provision_complete` actions via Apps Script
- Operator initials prompt — written to column R ("Operator name - Phase 1") in tracking sheet
- Case number prompt — clarified that Enter = matches device number or unknown
- Critical flash failure detection — distinguishes harmless `ecfw` failures from fatal partition errors (kernel, system, etc.); hard stops with loud error and `flash_failed` sheet update
- Update check at startup — all scripts fetch `origin/main` and hard-stop if behind; skips gracefully if offline
- `ml_provision.sh` skips update check when called from `ml_os_flash.sh` (env-based)
- Friendly OS version naming — `os_images/` subdirectories named by version (e.g. `1.4.1`) rather than build string; auto-selects if only one version present; prompts with numbered menu if multiple; falls back to menu if named version not found
- Version display — all scripts show current git tag in banner; `update.sh` shows before/after

### Fixed
- macOS compatibility patches for `flashall_amd.sh` (Apple Silicon + Intel): `stat`, `lsusb`, Darwin binary paths, `usbrecovery_host`
- `fastboot reboot` loop — script kicks device out of fastboot after `ecfw` failure

### Notes
- Target OS: 1.4.1 (B3E.230928.10-R.098)
- WiFi: KAGAMI / KAGAmius
- App package: com.tindrum.kagami
- Fleet ADB key: `authorized_keys/adbkey_kagami_fleet` (distributed separately)

---

*Older entries will be added here as the project history is tagged.*
