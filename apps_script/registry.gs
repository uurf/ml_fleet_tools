/* ============================================================
 * registry.gs — Device→Show membership registry (Apps Script web app)
 * ------------------------------------------------------------
 * The canonical, single-purpose store for "which show is each device in,
 * right now" — separate from the per-show tracking/log sheets (which drift).
 *
 * ONE row per device, keyed on the immutable hardware Serial:
 *     Serial | Show | Device | Status | Source | Updated
 * A migration is an UPDATE of the Show cell on that serial's row — never a
 * move between sheets — so a device CANNOT be in two shows at once (the bug
 * that caused the red/blue dedup mess is structurally impossible here).
 *
 * WRITE  (POST, JSON):  upsert by serial. Tools POST, humans never edit.
 *   body: {"serial":"G…","show":"KAGAMI_BLUE","device":"123",
 *          "status":"active","source":"migrate"}
 *   - serial is required; only provided fields are updated; Updated is stamped.
 *   - finds the row by Serial (trim + case-insensitive); inserts if new.
 *   returns: {"ok":true,"action":"updated"|"inserted","serial":"…","show":"…"}
 *
 * READ   (GET):
 *   ?format=inventory&show=KAGAMI  -> "Device,Serial\n…"  (exactly what
 *        fleet_dashboard.html loadCSV() expects → point the dashboard here)
 *   ?format=csv [&show=…]          -> full CSV (all columns), optional filter
 *   ?format=json [&show=…]         -> array of row objects
 *   (default: format=csv, all shows)
 *
 * DEPLOY (per the dedicated registry workbook — NOT the tracking sheets):
 *   1. Create a new Google Sheet (the registry). Extensions → Apps Script.
 *   2. Paste this file. Set SHEET_TAB_NAME below to the tab name.
 *   3. Deploy → New deployment → Web app; Execute as: Me; Who has access:
 *      "Anyone" (it's serial/show data, no secrets) → copy the /exec URL.
 *   4. Put that URL in the toolkit (single value, shared by all shows) and
 *      have ml_provision / ml_show_migrate POST upserts to it.
 *   Columns auto-create on first write; lookups are by header text so the
 *   column order can change safely.
 * ============================================================ */

const SHEET_TAB_NAME = 'Registry';
const HEADERS = ['Serial', 'Show', 'Device', 'Status', 'Source', 'Updated'];

function sheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_TAB_NAME);
  if (!sh) sh = ss.insertSheet(SHEET_TAB_NAME);
  if (sh.getLastRow() === 0) sh.appendRow(HEADERS);   // self-create header
  return sh;
}

function colMap_(sh) {
  const hdr = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  const m = {};
  hdr.forEach((h, i) => { m[String(h).trim().toLowerCase()] = i; }); // 0-based
  return m;
}

function norm_(v) { return String(v == null ? '' : v).trim(); }
function key_(v) { return norm_(v).toUpperCase(); }

function json_(obj, code) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
function text_(s) {
  return ContentService.createTextOutput(s).setMimeType(ContentService.MimeType.TEXT);
}

// ── WRITE: upsert by serial ──────────────────────────────────
function doPost(e) {
  const lock = LockService.getScriptLock();      // serialize concurrent writes
  try { lock.waitLock(20000); } catch (err) { return json_({ ok: false, error: 'busy' }); }
  try {
    let body = {};
    try { body = JSON.parse((e && e.postData && e.postData.contents) || '{}'); }
    catch (err) { return json_({ ok: false, error: 'bad json' }); }

    const serial = norm_(body.serial);
    if (!serial) return json_({ ok: false, error: 'serial required' });

    const sh = sheet_();
    const m = colMap_(sh);
    const cSerial = m['serial'], cShow = m['show'], cDev = m['device'],
          cStatus = m['status'], cSource = m['source'], cUpdated = m['updated'];
    const now = new Date().toISOString();

    // find existing row by serial (case-insensitive)
    const last = sh.getLastRow();
    let rowIdx = -1;
    if (last >= 2) {
      const serials = sh.getRange(2, cSerial + 1, last - 1, 1).getValues();
      for (let i = 0; i < serials.length; i++) {
        if (key_(serials[i][0]) === key_(serial)) { rowIdx = i + 2; break; }
      }
    }

    const setIf = (row, col, val) => {
      if (col == null) return;
      if (val !== undefined && val !== null && String(val) !== '') sh.getRange(row, col + 1).setValue(val);
    };

    if (rowIdx === -1) {
      // insert
      const r = new Array(sh.getLastColumn()).fill('');
      r[cSerial] = serial;
      if (cShow != null && body.show !== undefined) r[cShow] = norm_(body.show);
      if (cDev != null && body.device !== undefined) r[cDev] = norm_(body.device);
      if (cStatus != null) r[cStatus] = norm_(body.status) || 'active';
      if (cSource != null) r[cSource] = norm_(body.source);
      if (cUpdated != null) r[cUpdated] = now;
      sh.appendRow(r);
      return json_({ ok: true, action: 'inserted', serial: serial, show: norm_(body.show) });
    }
    // update (only provided fields)
    setIf(rowIdx, cShow, norm_(body.show));
    setIf(rowIdx, cDev, norm_(body.device));
    setIf(rowIdx, cStatus, norm_(body.status));
    setIf(rowIdx, cSource, norm_(body.source));
    if (cUpdated != null) sh.getRange(rowIdx, cUpdated + 1).setValue(now);
    return json_({ ok: true, action: 'updated', serial: serial, show: norm_(body.show) });
  } finally {
    lock.releaseLock();
  }
}

// ── READ ─────────────────────────────────────────────────────
function doGet(e) {
  const p = (e && e.parameter) || {};
  const fmt = (p.format || 'csv').toLowerCase();
  const showFilter = p.show ? key_(p.show) : '';

  const sh = sheet_();
  const last = sh.getLastRow();
  const hdr = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(h => String(h).trim());
  const m = colMap_(sh);
  const rows = last >= 2 ? sh.getRange(2, 1, last - 1, sh.getLastColumn()).getValues() : [];

  const keep = rows.filter(r => !showFilter || key_(r[m['show']]) === showFilter);

  if (fmt === 'inventory') {
    // Device,Serial — matches fleet_dashboard.html loadCSV()
    const out = ['Device,Serial'];
    keep.forEach(r => out.push([norm_(r[m['device']]), norm_(r[m['serial']])].join(',')));
    return text_(out.join('\n'));
  }
  if (fmt === 'json') {
    const arr = keep.map(r => {
      const o = {}; hdr.forEach((h, i) => { o[h] = r[i]; }); return o;
    });
    return json_(arr);
  }
  // full csv
  const csv = [hdr.join(',')];
  keep.forEach(r => csv.push(hdr.map((h, i) => {
    const v = String(r[i] == null ? '' : r[i]);
    return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
  }).join(',')));
  return text_(csv.join('\n'));
}
