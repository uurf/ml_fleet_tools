/**
 * KAGAMI Fleet — Google Apps Script
 * Tin Drum / Magic Leap 2 Fleet Management
 *
 * Deploy as a Web App:
 *   Extensions → Apps Script → Deploy → New deployment
 *   Type: Web app
 *   Execute as: Me
 *   Who has access: Anyone
 *
 * Called automatically by os_downgrade.sh and ml_provision.sh
 */

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const sheet = SpreadsheetApp.getActiveSpreadsheet()
      .getSheetByName("Kagami Osaka - Device status");

    // Find column by header text — survives column insertions/moves
    const headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    function col(headerText) {
      const idx = headers.findIndex(h => String(h).trim() === headerText.trim());
      return idx === -1 ? null : idx + 1;
    }

    const deviceNumCol       = col("Device #");
    const statusCol          = col("Status");
    const serialCol          = col("Device Serial Number");
    const os141Col           = col("OS 1.4.1 (B3E.230928.10-R.098)");
    const devModeCol         = col("Enable Developer mode : Settings/About/Click Build Number 7 Times ");
    const batterySaverCol    = col("Battery: Battery Saver:  off");
    // Manual — never set by script:
    // const computeStandbyCol  = col("Battery: Compute Pack Standby: Off");
    // const displayOverrideCol = col("Display: Display Override: Off");
    const displayModesCol    = col("Display Modes: none");
    const autoBrightCol      = col("Display: Auto Brightness: Off");
    const brightnessCol      = col("Display: Brightness : 12");
    // Manual — never set by script:
    // const globalDimCol       = col("Display: Global Dimming: just below max, even with h in 'light'");
    // const segDimmingCol      = col("Display: Segmented Dimming: On");
    // const maxDimCol          = col("Display: Maximum Dimming: just below max, even with l in 'display'");
    // const osUpdaterCol       = col("System: Advanced: Os Updater: Check for updates: Never");
    const wifiCol            = col("Connect device to KAGAMI WiFi");
    const kioskScriptCol     = col("Kiosk mode script");
    const deployApkCol       = col("Deploy Kagami APK 1.24");
    const grantPermsCol      = col("Grant App Access Permissions");
    const removeAppsCol      = col("Remove other apps (An Ark, The Life, Medusa)");
    const notesCol           = col("Notes");
    const operatorCol        = col("Operator name - Phase 1");

    const lastRow = sheet.getLastRow();

    // Find existing row by serial number
    let targetRow = null;
    for (let i = 2; i <= lastRow; i++) {
      if (sheet.getRange(i, serialCol).getValue() === data.serial) {
        targetRow = i;
        break;
      }
    }

    // If not found, find next empty row
    if (!targetRow) {
      for (let i = 2; i <= lastRow + 1; i++) {
        if (!sheet.getRange(i, serialCol).getValue() &&
            !sheet.getRange(i, deviceNumCol).getValue()) {
          targetRow = i;
          break;
        }
      }
    }

    // Always write serial
    sheet.getRange(targetRow, serialCol).setValue(data.serial);

    if (data.device_number) {
      sheet.getRange(targetRow, deviceNumCol).setValue(data.device_number);
    }

    if (data.case_number) {
      sheet.getRange(targetRow, notesCol).setValue("in case " + data.case_number);
    }

    if (data.action === "flash_failed") {
      sheet.getRange(targetRow, statusCol).setValue("⚠ Flash failed — do not use");
      if (data.operator_initials && operatorCol) {
        sheet.getRange(targetRow, operatorCol).setValue(data.operator_initials);
      }

    } else if (data.action === "flash_start") {
      sheet.getRange(targetRow, statusCol).setValue("Firmware update in progress");
      if (data.operator_initials && operatorCol) {
        sheet.getRange(targetRow, operatorCol).setValue(data.operator_initials);
      }

    } else if (data.action === "flash_complete") {
      sheet.getRange(targetRow, os141Col).setValue(true);
      if (removeAppsCol) sheet.getRange(targetRow, removeAppsCol).setValue(true);
      sheet.getRange(targetRow, statusCol).setValue("Firmware update in progress");
      // Confirm initials at flash_complete — catches cases where flash_start fired without network
      if (data.operator_initials && operatorCol) {
        sheet.getRange(targetRow, operatorCol).setValue(data.operator_initials);
      }

    } else if (data.action === "deploy_complete") {
      if (kioskScriptCol) sheet.getRange(targetRow, kioskScriptCol).setValue(true);
      if (deployApkCol)   sheet.getRange(targetRow, deployApkCol).setValue(true);
      if (grantPermsCol)  sheet.getRange(targetRow, grantPermsCol).setValue(true);
      sheet.getRange(targetRow, statusCol).setValue("Ready for asset loading");

    } else if (data.action === "provision_start") {
      sheet.getRange(targetRow, statusCol).setValue("Configuration in progress");
      // Fallback: write initials if not already set (e.g. ml_provision.sh run standalone)
      if (data.operator_initials && operatorCol) {
        if (!sheet.getRange(targetRow, operatorCol).getValue()) {
          sheet.getRange(targetRow, operatorCol).setValue(data.operator_initials);
        }
      }

    } else if (data.action === "provision_complete") {
      sheet.getRange(targetRow, statusCol).setValue("Configuration in progress");
      sheet.getRange(targetRow, devModeCol).setValue(true);
      sheet.getRange(targetRow, batterySaverCol).setValue(true);
      sheet.getRange(targetRow, displayModesCol).setValue(true);
      sheet.getRange(targetRow, autoBrightCol).setValue(true);
      sheet.getRange(targetRow, brightnessCol).setValue(true);
      if (data.wifi_connected === "true") {
        sheet.getRange(targetRow, wifiCol).setValue(true);
      }
      // Same fallback as provision_start
      if (data.operator_initials && operatorCol) {
        if (!sheet.getRange(targetRow, operatorCol).getValue()) {
          sheet.getRange(targetRow, operatorCol).setValue(data.operator_initials);
        }
      }
    }

    return ContentService.createTextOutput(JSON.stringify({status: "ok", row: targetRow}))
      .setMimeType(ContentService.MimeType.JSON);

  } catch(err) {
    return ContentService.createTextOutput(JSON.stringify({status: "error", message: err.toString()}))
      .setMimeType(ContentService.MimeType.JSON);
  }
}
