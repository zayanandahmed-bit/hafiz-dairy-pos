# Hafiz Dairy — POS System

A single-file, offline-friendly point-of-sale app for a grocery/dairy store: billing, inventory (with or without barcodes), purchases & suppliers, cashier shifts, refunds, and receipt printing.

Live app: `index.html` — open it directly, or visit the GitHub Pages URL once enabled.

## Cloud Sync (optional)

The app can sync its data to a Google Sheet through a small Apps Script backend. See `google-apps-script.gs` for the script and setup instructions (comments at the top of the file). Once deployed, paste the Web App URL and your chosen secret into the app's **Settings → Cloud Sync** panel.

No credentials or secrets are stored in this repository — the Cloud Sync URL and secret are entered at runtime and kept only in the browser's local storage on each device.
