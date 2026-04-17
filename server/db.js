import Database from 'better-sqlite3';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const db = new Database(join(__dirname, 'plaid.db'));

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

export default db;
