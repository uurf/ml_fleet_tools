/* ============================================================
 * KAGAMI tracker maintenance — Red ↔ Blue reconciliation
 * ------------------------------------------------------------
 * Durable copy of the one-off maintenance functions used to clean
 * the two device-tracking Google Sheets (Osaka, 2026-06). Lives here
 * because the bound copy in the "KAGAMI Fleet API" Apps Script project
 * is not version-controlled and was lost once.
 *
 * HOW TO USE
 *   1. Open the Apps Script project for the tracking workbook
 *      (Extensions → Apps Script). Add a NEW file (e.g. Reconcile.gs);
 *      do NOT edit Code.gs (that's the deployed provisioning web app).
 *   2. Paste this whole file in. Save.
 *   3. Pick a function in the editor dropdown and Run; read the
 *      Execution log. First run prompts for authorization (runs as you).
 *
 * FUNCTIONS (each self-contained — own constants, no global clashes):
 *   diagnose()      READ-ONLY. Red audit (rows / non-blank / unique /
 *                   blanks / within-Red dups) + where the wrong-show
 *                   units sit in Blue.
 *   diagnoseBlue()  READ-ONLY. Same audit for Blue (internal dups).
 *   reconcileRed()  Removes from Red any serial present in Blue (a
 *                   device "moved to Blue but not removed from Red"),
 *                   plus within-Red duplicates. DRY_RUN by default —
 *                   logs what it WOULD delete; set DRY_RUN=false to
 *                   actually delete. Only ever removes a Red serial
 *                   confirmed live in Blue, so it can't orphan a device.
 *
 * SAFETY
 *   - Always run with DRY_RUN=true first and review the log.
 *   - Back up the sheet first (File → Make a copy).
 *   - Serials are compared normalized (trim + uppercase).
 *   - reconcileRed reads Blue LIVE each run (no stale snapshot).
 *
 * Sheet identifiers (Osaka):
 *   RED  = 1dOLJ3O7AoMrxvZTr131zPhiqXHEV2-QEkknq-rtl1bk
 *          tab "Kagami Osaka - Device status"
 *   BLUE = 1HCc6aAhGuwI-nZbqvVAzazNT8cu-BriC7U2a8u9gN-s
 *          tab "Kagami Osaka - Blue Device status"
 *   Serial header (both): "Device Serial Number"
 * ============================================================ */

function reconcileRed(){
  const RED_ID    = '1dOLJ3O7AoMrxvZTr131zPhiqXHEV2-QEkknq-rtl1bk';
  const RED_TAB   = 'Kagami Osaka - Device status';
  const BLUE_ID   = '1HCc6aAhGuwI-nZbqvVAzazNT8cu-BriC7U2a8u9gN-s';
  const BLUE_TAB  = 'Kagami Osaka - Blue Device status';
  const HEADER     = 'Device Serial Number';
  const HEADER_ROW = 1;
  const WRONG_SHOW = ['G962XT0200J6','G962XT0200FP','GB62XT0000F4','GA62XT0100CW'];
  const DRY_RUN = true;   // <-- true = preview only; set false to actually delete

  const norm = v => String(v).trim().toUpperCase();
  const colIndex = (values, header) => {
    const row = values[HEADER_ROW-1].map(h => String(h).trim().toLowerCase());
    const i = row.indexOf(header.toLowerCase());
    if (i < 0) throw new Error('Header "'+header+'" not found in row '+HEADER_ROW);
    return i;
  };

  const blueSh = SpreadsheetApp.openById(BLUE_ID).getSheetByName(BLUE_TAB);
  if (!blueSh) throw new Error('Blue tab not found: '+BLUE_TAB);
  const blueVals = blueSh.getDataRange().getValues();
  const blueCol = colIndex(blueVals, HEADER);
  const blue = new Set();
  for (let r = HEADER_ROW; r < blueVals.length; r++){ const s = norm(blueVals[r][blueCol]); if (s) blue.add(s); }

  const redSh = SpreadsheetApp.openById(RED_ID).getSheetByName(RED_TAB);
  if (!redSh) throw new Error('Red tab not found: '+RED_TAB);
  const redVals = redSh.getDataRange().getValues();
  const redCol = colIndex(redVals, HEADER);
  const toDelete = [];
  const seen = new Set();
  for (let r = HEADER_ROW; r < redVals.length; r++){
    const s = norm(redVals[r][redCol]);
    if (!s) continue;
    if (blue.has(s))      toDelete.push({row:r+1, serial:s, reason:'in BLUE'});
    else if (seen.has(s)) toDelete.push({row:r+1, serial:s, reason:'DUP within RED (keeping first)'});
    else seen.add(s);
  }
  const wrong = WRONG_SHOW.map(w => {
    const n = norm(w);
    return n + (blue.has(n) ? '  -> in Blue (will be removed from Red)'
                            : '  -> NOT in Blue → MANUAL MOVE NEEDED (not deleted)');
  });
  Logger.log('Blue serials: %s', blue.size);
  Logger.log('Red data rows: %s', redVals.length - HEADER_ROW);
  Logger.log('=== %s row(s) to delete from Red ===', toDelete.length);
  toDelete.forEach(d => Logger.log('row %s | %s | %s', d.row, d.serial, d.reason));
  Logger.log('=== wrong-show devices ===\n%s', wrong.join('\n'));
  if (DRY_RUN){ Logger.log('DRY_RUN = true → no changes. Set DRY_RUN=false and run again to delete.'); return; }
  toDelete.map(d=>d.row).sort((a,b)=>b-a).forEach(row => redSh.deleteRow(row));
  Logger.log('DELETED %s row(s). Red rows: %s → %s', toDelete.length,
             redVals.length-HEADER_ROW, redVals.length-HEADER_ROW-toDelete.length);
}

function diagnose(){
  const RED_ID='1dOLJ3O7AoMrxvZTr131zPhiqXHEV2-QEkknq-rtl1bk';
  const RED_TAB='Kagami Osaka - Device status';
  const BLUE_ID='1HCc6aAhGuwI-nZbqvVAzazNT8cu-BriC7U2a8u9gN-s';
  const BLUE_TAB='Kagami Osaka - Blue Device status';
  const HEADER='Device Serial Number', HEADER_ROW=1;
  const CHECK=['G962XT0200J6','G962XT0200FP','GB62XT0000F4','GA62XT0100CW'];
  const norm=v=>String(v).trim().toUpperCase();
  const col=vals=>vals[HEADER_ROW-1].map(h=>String(h).trim().toLowerCase()).indexOf(HEADER.toLowerCase());

  const bv=SpreadsheetApp.openById(BLUE_ID).getSheetByName(BLUE_TAB).getDataRange().getValues();
  const bc=col(bv);
  CHECK.forEach(w=>{
    const n=norm(w), hits=[];
    for(let r=HEADER_ROW;r<bv.length;r++) if(norm(bv[r][bc])===n) hits.push('Blue row '+(r+1)+' raw="'+bv[r][bc]+'"');
    Logger.log('%s : %s', w, hits.length?hits.join(' ; '):'NOT in Blue');
  });
  const rv=SpreadsheetApp.openById(RED_ID).getSheetByName(RED_TAB).getDataRange().getValues();
  const rc=col(rv);
  const counts={}; let nonblank=0, blanks=0;
  for(let r=HEADER_ROW;r<rv.length;r++){ const s=norm(rv[r][rc]); if(!s){blanks++;continue;} nonblank++; counts[s]=(counts[s]||0)+1; }
  const dups=Object.keys(counts).filter(k=>counts[k]>1);
  Logger.log('RED: rows=%s  non-blank serials=%s  unique=%s  blank-serial rows=%s',
             rv.length-HEADER_ROW, nonblank, Object.keys(counts).length, blanks);
  Logger.log('RED within-sheet dup serials: %s', dups.length? dups.map(k=>k+'×'+counts[k]).join(', '):'none');
}

function diagnoseBlue(){
  const BLUE_ID='1HCc6aAhGuwI-nZbqvVAzazNT8cu-BriC7U2a8u9gN-s';
  const BLUE_TAB='Kagami Osaka - Blue Device status';
  const HEADER='Device Serial Number', HEADER_ROW=1;
  const norm=v=>String(v).trim().toUpperCase();
  const col=vals=>vals[HEADER_ROW-1].map(h=>String(h).trim().toLowerCase()).indexOf(HEADER.toLowerCase());

  const sh=SpreadsheetApp.openById(BLUE_ID).getSheetByName(BLUE_TAB);
  if(!sh) throw new Error('Blue tab not found: '+BLUE_TAB);
  const vals=sh.getDataRange().getValues();
  const c=col(vals);
  if(c<0) throw new Error('Header "'+HEADER+'" not found in row '+HEADER_ROW);
  const rowsBySerial={}; let nonblank=0, blanks=0;
  for(let r=HEADER_ROW;r<vals.length;r++){
    const s=norm(vals[r][c]);
    if(!s){blanks++;continue;}
    nonblank++;
    (rowsBySerial[s]=rowsBySerial[s]||[]).push(r+1);
  }
  const unique=Object.keys(rowsBySerial).length;
  const dups=Object.keys(rowsBySerial).filter(k=>rowsBySerial[k].length>1);
  Logger.log('BLUE: rows=%s  non-blank serials=%s  unique=%s  blank-serial rows=%s',
             vals.length-HEADER_ROW, nonblank, unique, blanks);
  Logger.log('BLUE within-sheet dup serials: %s',
             dups.length ? dups.length+' -> '+dups.map(k=>k+' (rows '+rowsBySerial[k].join(',')+')').join('; ') : 'none');
}
