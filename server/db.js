import Database from 'better-sqlite3';
import { chmodSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { encrypt, isEncrypted } from './lib/crypto.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const dbPath = join(__dirname, 'plaid.db');
const db = new Database(dbPath);

// Restrict the DB file to owner-only read/write. Even with access-token
// encryption, other columns (institution_id, webhook history) should not
// be world-readable.
try { chmodSync(dbPath, 0o600); } catch { /* best-effort on non-POSIX */ }

db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS plaid_items (
    id TEXT PRIMARY KEY,
    item_id TEXT UNIQUE NOT NULL,
    access_token TEXT NOT NULL,
    institution_id TEXT,
    institution_name TEXT,
    created_at TEXT DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS plaid_accounts (
    id TEXT PRIMARY KEY,
    plaid_item_id TEXT NOT NULL,
    plaid_account_id TEXT UNIQUE NOT NULL,
    name TEXT,
    official_name TEXT,
    type TEXT,
    subtype TEXT,
    mask TEXT,
    FOREIGN KEY (plaid_item_id) REFERENCES plaid_items(id) ON DELETE CASCADE
  );

  CREATE TABLE IF NOT EXISTS sync_cursors (
    plaid_item_id TEXT PRIMARY KEY,
    cursor TEXT,
    last_synced_at TEXT,
    FOREIGN KEY (plaid_item_id) REFERENCES plaid_items(id) ON DELETE CASCADE
  );

  CREATE TABLE IF NOT EXISTS webhook_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    webhook_type TEXT NOT NULL,
    webhook_code TEXT NOT NULL,
    item_id TEXT,
    payload TEXT NOT NULL,
    verified INTEGER DEFAULT 0,
    received_at TEXT DEFAULT (datetime('now'))
  );

  CREATE INDEX IF NOT EXISTS idx_webhook_events_item_id ON webhook_events(item_id);
  CREATE INDEX IF NOT EXISTS idx_webhook_events_received_at ON webhook_events(received_at);
`);

// Lightweight migration: add balance columns to plaid_accounts if missing.
// Balance responses include current/available balance, limit (for credit
// cards), the account currency, and a timestamp of when Plaid last got
// the figure from the bank. We also store our own fetched_at so the
// macOS app can show "last refreshed" text.
function addColumnIfMissing(table, column, typeDecl) {
  const columns = db.prepare(`PRAGMA table_info(${table})`).all();
  if (!columns.some((c) => c.name === column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${typeDecl}`);
  }
}

addColumnIfMissing('plaid_accounts', 'balance_current', 'REAL');
addColumnIfMissing('plaid_accounts', 'balance_available', 'REAL');
addColumnIfMissing('plaid_accounts', 'balance_limit', 'REAL');
addColumnIfMissing('plaid_accounts', 'balance_iso_currency_code', 'TEXT');
addColumnIfMissing('plaid_accounts', 'balance_last_updated_plaid', 'TEXT');
addColumnIfMissing('plaid_accounts', 'balance_fetched_at', 'TEXT');

// Identity columns. Plaid returns arrays of owners per account; we keep
// the primary (first) owner for quick display and stash the full JSON
// blob so we can render secondary owners or verify details if needed.
addColumnIfMissing('plaid_accounts', 'owner_name', 'TEXT');
addColumnIfMissing('plaid_accounts', 'owner_email', 'TEXT');
addColumnIfMissing('plaid_accounts', 'owner_phone', 'TEXT');
addColumnIfMissing('plaid_accounts', 'owners_json', 'TEXT');
addColumnIfMissing('plaid_accounts', 'identity_fetched_at', 'TEXT');

// Transactions lifecycle flags (per item). Plaid fetches history in two
// phases — a fast "last 30 days" pass (initial_update_complete) and a
// slower full backfill (historical_update_complete). We surface both to
// the app so the UI can show "still backfilling, check back later"
// messaging instead of a misleading empty state.
addColumnIfMissing('sync_cursors', 'initial_update_complete', 'INTEGER DEFAULT 0');
addColumnIfMissing('sync_cursors', 'historical_update_complete', 'INTEGER DEFAULT 0');
addColumnIfMissing('sync_cursors', 'pending_update_available', 'INTEGER DEFAULT 0');

// Update-mode flags on the item itself. ITEM_LOGIN_REQUIRED means the
// user's credentials are broken right now; PENDING_EXPIRATION /
// PENDING_DISCONNECT are 7-day heads-ups from regulators. We track all
// three separately so the UI can distinguish "must fix now" from
// "should fix soon". reason holds the most recent webhook code or
// error code so we can tell the user why.
addColumnIfMissing('plaid_items', 'needs_update', 'INTEGER DEFAULT 0');
addColumnIfMissing('plaid_items', 'needs_update_reason', 'TEXT');
addColumnIfMissing('plaid_items', 'needs_update_detected_at', 'TEXT');

// One-time migration: encrypt any plaintext access tokens in place.
// isEncrypted() detects the v1 blob prefix, so running this multiple
// times is a no-op. New tokens go in encrypted from the start (see
// routes/plaid.js).
(function migratePlaintextTokens() {
  const rows = db.prepare('SELECT id, access_token FROM plaid_items').all();
  const update = db.prepare('UPDATE plaid_items SET access_token = ? WHERE id = ?');
  let migrated = 0;
  const migrateAll = db.transaction(() => {
    for (const row of rows) {
      if (!isEncrypted(row.access_token)) {
        update.run(encrypt(row.access_token), row.id);
        migrated++;
      }
    }
  });
  migrateAll();
  if (migrated > 0) {
    console.log(`[crypto] Encrypted ${migrated} legacy access token(s) at rest`);
  }
})();

// One-time migration: encrypt any plaintext owners_json blobs. These
// contain full mailing addresses from Plaid Identity and are our
// highest PII concentration. Same pattern as access_token: skip rows
// already encrypted.
(function migratePlaintextOwners() {
  const rows = db
    .prepare('SELECT plaid_account_id, owners_json FROM plaid_accounts WHERE owners_json IS NOT NULL')
    .all();
  const update = db.prepare('UPDATE plaid_accounts SET owners_json = ? WHERE plaid_account_id = ?');
  let migrated = 0;
  const migrateAll = db.transaction(() => {
    for (const row of rows) {
      if (!isEncrypted(row.owners_json)) {
        update.run(encrypt(row.owners_json), row.plaid_account_id);
        migrated++;
      }
    }
  });
  migrateAll();
  if (migrated > 0) {
    console.log(`[crypto] Encrypted ${migrated} legacy owners_json blob(s) at rest`);
  }
})();

// Retention policy: webhook_events are operational logs, not data the
// app needs long-term. Keep 30 days for debugging then drop. Runs once
// on startup and every hour after.
function pruneOldWebhookEvents() {
  const result = db
    .prepare(`DELETE FROM webhook_events WHERE received_at < datetime('now', '-30 days')`)
    .run();
  if (result.changes > 0) {
    console.log(`[retention] Pruned ${result.changes} webhook_events older than 30 days`);
  }
}
pruneOldWebhookEvents();
setInterval(pruneOldWebhookEvents, 60 * 60 * 1000);

export default db;
