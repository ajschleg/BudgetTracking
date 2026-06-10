/**
 * Nightly on-disk backups of plaid.db.
 *
 * Now that the server is the source of truth for transactions, this file
 * is the one copy of the books that matters — losing it means re-seeding
 * from a device cache and relinking history. better-sqlite3's native
 * db.backup() takes a consistent online snapshot (safe under WAL while
 * the server is serving), so no external sqlite3 CLI or launchd job is
 * needed.
 *
 * Cadence: server.js calls runBackupIfDue() hourly; the function is a
 * no-op until the UTC date rolls over (one backup per day, idempotent
 * across restarts because the check is "does today's file exist").
 * Retention: newest 14, pruned by filename sort. Backups inherit the
 * same posture as the live DB: 0600 files in a 0700 dir, gitignored.
 */

import { existsSync, mkdirSync, chmodSync, readdirSync, unlinkSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import db from '../db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BACKUP_DIR = join(__dirname, '..', 'backups');
const KEEP = 14;
const NAME_RE = /^plaid-\d{8}\.db$/;

export async function runBackupIfDue() {
  const today = new Date().toISOString().slice(0, 10).replaceAll('-', '');
  const target = join(BACKUP_DIR, `plaid-${today}.db`);
  if (existsSync(target)) return;

  mkdirSync(BACKUP_DIR, { recursive: true, mode: 0o700 });
  await db.backup(target);
  chmodSync(target, 0o600);

  const files = readdirSync(BACKUP_DIR)
    .filter((f) => NAME_RE.test(f))
    .sort();
  for (const f of files.slice(0, Math.max(0, files.length - KEEP))) {
    unlinkSync(join(BACKUP_DIR, f));
  }
  console.log(
    `[backup] Wrote backups/plaid-${today}.db (${Math.min(files.length, KEEP)} retained)`
  );
}
