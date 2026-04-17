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

export default db;
