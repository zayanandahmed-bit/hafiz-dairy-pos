/**
 * Hafiz Dairy POS — Cloud Sync backend.
 *
 * Turns a Google Sheet into a proper multi-tab database for the POS app:
 * Items, Sales (+ SaleLines), Purchases (+ ProofImages), Categories,
 * Suppliers, Cashiers, Shifts, ActiveShift, Refunds (+ RefundLines),
 * HeldSales, Settings, and Meta — each as its own readable tab with real
 * columns, not a blob of JSON text.
 *
 * Every save in the app sends the FULL current dataset, and this script
 * fully rewrites each tab to match (clears + re-writes), so the Sheet is
 * always an exact mirror of the app's data after each change.
 *
 * SETUP (one-time, in your own Google account):
 * 1. Go to https://sheets.google.com and create (or reuse) a spreadsheet.
 * 2. Extensions -> Apps Script.
 * 3. Delete whatever is in Code.gs, paste this entire file in its place.
 * 4. Set SECRET below to your own password-like string (must match exactly
 *    what you enter in the app's Settings -> Cloud Sync -> Secret Token).
 * 5. Deploy -> Manage deployments -> edit (pencil) -> New version -> Deploy.
 *    (If this is a brand new script instead, use Deploy -> New deployment,
 *    type "Web app", Execute as "Me", Who has access "Anyone".)
 * 6. Copy the Web app URL (ends in /exec) into the app's Cloud Sync settings.
 */

var SECRET = "hafizdairy123";

// ---------- generic table helpers ----------

function getSheet_(name) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  return ss.getSheetByName(name) || ss.insertSheet(name);
}

function writeTable_(sheetName, headers, objects) {
  var sh = getSheet_(sheetName);
  sh.clearContents();
  sh.appendRow(headers);
  if (objects.length === 0) return;
  var rows = objects.map(function (obj) {
    return headers.map(function (h) {
      var v = obj[h];
      return v === undefined || v === null ? "" : v;
    });
  });
  sh.getRange(2, 1, rows.length, headers.length).setValues(rows);
}

function readTable_(sheetName, headers) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(sheetName);
  if (!sh) return [];
  var data = sh.getDataRange().getValues();
  if (data.length < 2) return [];
  var out = [];
  for (var i = 1; i < data.length; i++) {
    var row = data[i];
    var blank = row.every(function (c) { return c === "" || c === null; });
    if (blank) continue;
    var obj = {};
    headers.forEach(function (h, idx) { obj[h] = row[idx]; });
    out.push(obj);
  }
  return out;
}

function num_(v) { var n = Number(v); return isNaN(n) ? 0 : n; }
function numOrNull_(v) { if (v === "" || v === null || v === undefined) return null; var n = Number(v); return isNaN(n) ? null : n; }

// ---------- Items ----------
var ITEM_HEADERS = ["id", "name", "barcode", "category", "price", "stock", "unit", "lowStock"];
function writeItems_(items) { writeTable_("Items", ITEM_HEADERS, items); }
function readItems_() {
  return readTable_("Items", ITEM_HEADERS).map(function (o) {
    o.price = num_(o.price); o.stock = num_(o.stock); o.lowStock = num_(o.lowStock);
    return o;
  });
}

// ---------- Categories ----------
function writeCategories_(cats) {
  var sh = getSheet_("Categories");
  sh.clearContents();
  sh.appendRow(["name"]);
  if (cats.length) sh.getRange(2, 1, cats.length, 1).setValues(cats.map(function (c) { return [c]; }));
}
function readCategories_() {
  return readTable_("Categories", ["name"]).map(function (o) { return o.name; });
}

// ---------- Suppliers ----------
var SUPPLIER_HEADERS = ["id", "name", "contact", "address"];
function writeSuppliers_(s) { writeTable_("Suppliers", SUPPLIER_HEADERS, s); }
function readSuppliers_() { return readTable_("Suppliers", SUPPLIER_HEADERS); }

// ---------- Cashiers ----------
var CASHIER_HEADERS = ["id", "name", "pin"];
function writeCashiers_(c) { writeTable_("Cashiers", CASHIER_HEADERS, c); }
function readCashiers_() { return readTable_("Cashiers", CASHIER_HEADERS); }

// ---------- Purchases (+ proof images kept in a separate tab) ----------
var PURCHASE_HEADERS = ["id", "date", "supplierId", "supplierName", "itemId", "itemName", "qty", "cost", "total", "notes", "hasProof"];
function writePurchases_(purchases) {
  writeTable_("Purchases", PURCHASE_HEADERS, purchases.map(function (p) {
    return Object.assign({}, p, { hasProof: p.proof ? "Yes" : "No" });
  }));
  var proofRows = purchases.filter(function (p) { return p.proof; });
  var sh = getSheet_("ProofImages");
  sh.clearContents();
  sh.appendRow(["purchaseId", "proofName", "proofDataUrl"]);
  if (proofRows.length) {
    sh.getRange(2, 1, proofRows.length, 3).setValues(proofRows.map(function (p) {
      return [p.id, p.proofName || "", p.proof];
    }));
  }
}
function readPurchases_() {
  var purchases = readTable_("Purchases", PURCHASE_HEADERS);
  var proofs = readTable_("ProofImages", ["purchaseId", "proofName", "proofDataUrl"]);
  var proofMap = {};
  proofs.forEach(function (p) { proofMap[p.purchaseId] = p; });
  return purchases.map(function (p) {
    p.qty = num_(p.qty); p.cost = num_(p.cost); p.total = num_(p.total);
    var pr = proofMap[p.id];
    p.proof = pr ? pr.proofDataUrl : null;
    p.proofName = pr ? pr.proofName : null;
    delete p.hasProof;
    return p;
  });
}

// ---------- Sales (+ line items in their own tab) ----------
var SALE_HEADERS = ["id", "receiptNo", "date", "customer", "cashier", "payment", "cash", "subtotal", "discountPct", "discountAmt", "taxPct", "taxAmt", "grand"];
var SALE_LINE_HEADERS = ["saleId", "receiptNo", "itemId", "itemName", "barcode", "price", "qty", "unit", "subtotal"];
function writeSales_(sales) {
  writeTable_("Sales", SALE_HEADERS, sales);
  var lineRows = [];
  sales.forEach(function (s) {
    (s.lines || []).forEach(function (l) {
      lineRows.push({
        saleId: s.id, receiptNo: s.receiptNo, itemId: l.itemId || "", itemName: l.name,
        barcode: l.barcode || "", price: l.price, qty: l.qty, unit: l.unit || "", subtotal: l.subtotal
      });
    });
  });
  writeTable_("SaleLines", SALE_LINE_HEADERS, lineRows);
}
function readSales_() {
  var sales = readTable_("Sales", SALE_HEADERS);
  sales.forEach(function (s) {
    s.cash = numOrNull_(s.cash);
    s.subtotal = num_(s.subtotal); s.discountPct = num_(s.discountPct); s.discountAmt = num_(s.discountAmt);
    s.taxPct = num_(s.taxPct); s.taxAmt = num_(s.taxAmt); s.grand = num_(s.grand);
    s.receiptNo = num_(s.receiptNo);
  });
  var lines = readTable_("SaleLines", SALE_LINE_HEADERS);
  var bySale = {};
  lines.forEach(function (l) {
    if (!bySale[l.saleId]) bySale[l.saleId] = [];
    bySale[l.saleId].push({
      itemId: l.itemId || null, name: l.itemName, barcode: l.barcode || "",
      price: num_(l.price), qty: num_(l.qty), unit: l.unit || "", subtotal: num_(l.subtotal)
    });
  });
  sales.forEach(function (s) { s.lines = bySale[s.id] || []; });
  return sales;
}

// ---------- Refunds (+ line items) ----------
var REFUND_HEADERS = ["id", "saleId", "receiptNo", "date", "total", "reason", "cashier"];
var REFUND_LINE_HEADERS = ["refundId", "itemId", "itemName", "qty", "price", "refundAmount"];
function writeRefunds_(refunds) {
  writeTable_("Refunds", REFUND_HEADERS, refunds);
  var lineRows = [];
  refunds.forEach(function (r) {
    (r.lines || []).forEach(function (l) {
      lineRows.push({ refundId: r.id, itemId: l.itemId || "", itemName: l.name, qty: l.qty, price: l.price, refundAmount: l.refundAmount });
    });
  });
  writeTable_("RefundLines", REFUND_LINE_HEADERS, lineRows);
}
function readRefunds_() {
  var refunds = readTable_("Refunds", REFUND_HEADERS);
  refunds.forEach(function (r) { r.receiptNo = num_(r.receiptNo); r.total = num_(r.total); });
  var lines = readTable_("RefundLines", REFUND_LINE_HEADERS);
  var byRefund = {};
  lines.forEach(function (l) {
    if (!byRefund[l.refundId]) byRefund[l.refundId] = [];
    byRefund[l.refundId].push({ itemId: l.itemId || null, name: l.itemName, qty: num_(l.qty), price: num_(l.price), refundAmount: num_(l.refundAmount) });
  });
  refunds.forEach(function (r) { r.lines = byRefund[r.id] || []; });
  return refunds;
}

// ---------- Held sales (+ cart contents in their own tab) ----------
var HELD_HEADERS = ["id", "date", "customer", "discount", "tax", "cashier"];
var HELD_CART_HEADERS = ["heldId", "itemId", "qty"];
function writeHeldSales_(held) {
  writeTable_("HeldSales", HELD_HEADERS, held);
  var cartRows = [];
  held.forEach(function (h) {
    (h.cart || []).forEach(function (line) {
      cartRows.push({ heldId: h.id, itemId: line.itemId, qty: line.qty });
    });
  });
  writeTable_("HeldSalesCart", HELD_CART_HEADERS, cartRows);
}
function readHeldSales_() {
  var held = readTable_("HeldSales", HELD_HEADERS);
  var cartRows = readTable_("HeldSalesCart", HELD_CART_HEADERS);
  var byHeld = {};
  cartRows.forEach(function (c) {
    if (!byHeld[c.heldId]) byHeld[c.heldId] = [];
    byHeld[c.heldId].push({ itemId: c.itemId, qty: num_(c.qty) });
  });
  held.forEach(function (h) { h.cart = byHeld[h.id] || []; });
  return held;
}

// ---------- Shifts (closed) ----------
var SHIFT_HEADERS = ["id", "cashierName", "start", "end", "openingCash", "cashSales", "cardSales", "walletSales", "cashRefunds", "txnCount", "expectedCash", "actualCash", "difference", "notes"];
function writeShifts_(shifts) { writeTable_("Shifts", SHIFT_HEADERS, shifts); }
function readShifts_() {
  return readTable_("Shifts", SHIFT_HEADERS).map(function (s) {
    ["openingCash", "cashSales", "cardSales", "walletSales", "cashRefunds", "txnCount", "expectedCash", "actualCash", "difference"].forEach(function (f) {
      s[f] = num_(s[f]);
    });
    return s;
  });
}

// ---------- Active shift (single object, or none) ----------
var ACTIVE_SHIFT_HEADERS = ["id", "cashierId", "cashierName", "start", "openingCash"];
function writeActiveShift_(shift) {
  writeTable_("ActiveShift", ACTIVE_SHIFT_HEADERS, shift ? [shift] : []);
}
function readActiveShift_() {
  var rows = readTable_("ActiveShift", ACTIVE_SHIFT_HEADERS);
  if (!rows.length) return null;
  var s = rows[0];
  s.openingCash = num_(s.openingCash);
  return s;
}

// ---------- Settings (single object as key/value rows) ----------
function writeSettings_(settings) {
  var sh = getSheet_("Settings");
  sh.clearContents();
  sh.appendRow(["setting", "value"]);
  var keys = Object.keys(settings);
  if (keys.length) {
    sh.getRange(2, 1, keys.length, 2).setValues(keys.map(function (k) { return [k, settings[k]]; }));
  }
}
function readSettings_() {
  var sh = getSheet_("Settings");
  var data = sh.getDataRange().getValues();
  var out = {};
  for (var i = 1; i < data.length; i++) {
    if (!data[i][0]) continue;
    out[data[i][0]] = data[i][1];
  }
  if (out.defaultTax !== undefined) out.defaultTax = num_(out.defaultTax);
  if (out.defaultDiscount !== undefined) out.defaultDiscount = num_(out.defaultDiscount);
  if (out.defaultLowStock !== undefined) out.defaultLowStock = num_(out.defaultLowStock);
  if (out.darkMode !== undefined) out.darkMode = (out.darkMode === true || out.darkMode === "TRUE" || out.darkMode === "true");
  return out;
}

// ---------- Meta (receipt counter etc.) ----------
function writeMeta_(key, value) {
  var sh = getSheet_("Meta");
  var data = sh.getDataRange().getValues();
  for (var i = 0; i < data.length; i++) {
    if (data[i][0] === key) { sh.getRange(i + 1, 2).setValue(value); return; }
  }
  sh.appendRow([key, value]);
}
function readMeta_(key) {
  var sh = getSheet_("Meta");
  var data = sh.getDataRange().getValues();
  for (var i = 0; i < data.length; i++) {
    if (data[i][0] === key) return data[i][1];
  }
  return null;
}

// ---------- dispatch ----------
function writeKey_(key, value) {
  if (key === "items") return writeItems_(value || []);
  if (key === "categories") return writeCategories_(value || []);
  if (key === "suppliers") return writeSuppliers_(value || []);
  if (key === "cashiers") return writeCashiers_(value || []);
  if (key === "purchases") return writePurchases_(value || []);
  if (key === "sales") return writeSales_(value || []);
  if (key === "refunds") return writeRefunds_(value || []);
  if (key === "heldSales") return writeHeldSales_(value || []);
  if (key === "shifts") return writeShifts_(value || []);
  if (key === "activeShift") return writeActiveShift_(value || null);
  if (key === "settings") return writeSettings_(value || {});
  if (key === "receiptCounter") return writeMeta_("receiptCounter", value);
}

function readAll_() {
  return {
    items: readItems_(),
    categories: readCategories_(),
    suppliers: readSuppliers_(),
    cashiers: readCashiers_(),
    purchases: readPurchases_(),
    sales: readSales_(),
    refunds: readRefunds_(),
    heldSales: readHeldSales_(),
    shifts: readShifts_(),
    activeShift: readActiveShift_(),
    settings: readSettings_(),
    receiptCounter: num_(readMeta_("receiptCounter")) || null
  };
}

// ---------- HTTP endpoints ----------
function jsonOut_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

function doGet(e) {
  var token = e.parameter.token;
  if (token !== SECRET) return jsonOut_({ ok: false, error: "unauthorized" });
  return jsonOut_({ ok: true, data: readAll_() });
}

function doPost(e) {
  var body;
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return jsonOut_({ ok: false, error: "bad request" });
  }
  if (body.token !== SECRET) return jsonOut_({ ok: false, error: "unauthorized" });

  if (body.entries && body.entries.length) {
    body.entries.forEach(function (entry) { writeKey_(entry.key, entry.value); });
  } else if (body.key) {
    writeKey_(body.key, body.value);
  } else {
    return jsonOut_({ ok: false, error: "nothing to write" });
  }
  return jsonOut_({ ok: true });
}
