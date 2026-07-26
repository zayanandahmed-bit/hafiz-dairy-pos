# Hafiz Dairy — POS System

A single-file, offline-friendly point-of-sale app for a grocery/dairy store: billing, inventory (with or without barcodes), purchases & suppliers, cashier shifts, refunds, and receipt printing.

Live app: `index.html` — open it directly, or visit the GitHub Pages URL once enabled.

## Cloud Sync (optional)

The app can sync its data to a Supabase database. See `supabase-schema.sql` for the schema, sync functions, and setup instructions (comments at the top of the file). Once your Supabase project is set up, paste the Project URL and anon key into the app's **Settings → Cloud Sync** panel.

No credentials or secrets are stored in this repository — the Cloud Sync URL and key are entered at runtime and kept only in the browser's local storage on each device.

`google-apps-script.gs` is kept in this repo as a fallback/reference for the previous Google Sheets-based sync backend; it is no longer what the app uses by default.
