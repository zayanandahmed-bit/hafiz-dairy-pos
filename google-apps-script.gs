/**
 * Hafiz Dairy POS — Cloud Sync backend.
 *
 * This turns a Google Sheet into a tiny JSON API so the POS app can save its
 * data (items, sales, categories, etc.) to the cloud and read it back later,
 * from any device.
 *
 * SETUP (one-time, in your own Google account):
 * 1. Go to https://sheets.google.com and create a new blank spreadsheet.
 *    Name it anything, e.g. "Hafiz Dairy POS Database".
 * 2. In the sheet, go to Extensions -> Apps Script.
 * 3. Delete whatever default code is in there, and paste this entire file in its place.
 * 4. Change the SECRET value below to your own random password-like string —
 *    anyone with your deployed URL AND this secret can read/write your data,
 *    so don't leave it as the placeholder and don't share it publicly.
 * 5. Click "Deploy" (top right) -> "New deployment".
 *    - Click the gear icon next to "Select type" and choose "Web app".
 *    - Description: anything, e.g. "POS API".
 *    - Execute as: "Me".
 *    - Who has access: "Anyone".
 * 6. Click "Deploy". The first time, Google will ask you to authorize the
 *    script — that's you granting your own script permission to edit your
 *    own sheet, it's normal and expected.
 * 7. Copy the "Web app URL" it gives you (it ends in /exec). That, together
 *    with your SECRET, goes into the POS app under Settings -> Cloud Sync.
 *
 * If you ever need to change the code later, edit it here, then
 * Deploy -> Manage deployments -> edit (pencil icon) -> New version -> Deploy,
 * so the same URL picks up your changes.
 */

var SECRET = "CHANGE-THIS-TO-YOUR-OWN-SECRET";
var SHEET_NAME = "Data";

function getSheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) {
    sh = ss.insertSheet(SHEET_NAME);
    sh.appendRow(["key", "value", "updatedAt"]);
  }
  return sh;
}

function readAll_() {
  var sh = getSheet_();
  var data = sh.getDataRange().getValues();
  var out = {};
  for (var i = 1; i < data.length; i++) {
    var key = data[i][0];
    var raw = data[i][1];
    if (!key) continue;
    try {
      out[key] = JSON.parse(raw);
    } catch (e) {
      out[key] = raw;
    }
  }
  return out;
}

function writeKey_(key, value) {
  var sh = getSheet_();
  var data = sh.getDataRange().getValues();
  var json = JSON.stringify(value);
  var now = new Date().toISOString();
  for (var i = 1; i < data.length; i++) {
    if (data[i][0] === key) {
      sh.getRange(i + 1, 2, 1, 2).setValues([[json, now]]);
      return;
    }
  }
  sh.appendRow([key, json, now]);
}

function jsonOut_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function doGet(e) {
  var token = e.parameter.token;
  if (token !== SECRET) {
    return jsonOut_({ ok: false, error: "unauthorized" });
  }
  return jsonOut_({ ok: true, data: readAll_() });
}

function doPost(e) {
  var body;
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return jsonOut_({ ok: false, error: "bad request" });
  }
  if (body.token !== SECRET) {
    return jsonOut_({ ok: false, error: "unauthorized" });
  }
  // Supports either a single {key, value} write, or a batch {entries: [{key,value}, ...]}
  if (body.entries && body.entries.length) {
    body.entries.forEach(function (entry) {
      writeKey_(entry.key, entry.value);
    });
  } else if (body.key) {
    writeKey_(body.key, body.value);
  } else {
    return jsonOut_({ ok: false, error: "nothing to write" });
  }
  return jsonOut_({ ok: true });
}
