/**
 * Server-side transaction store — the source of truth for transactions.
 *
 * Devices pull deltas with GET /api/transactions/changes?since=<seq> and
 * push writes through POST/PATCH. Every row mutation stamps a fresh
 * change_seq drawn from a global counter (transactions_sync_state), so
 * client cursors are immune to clock skew and to seq reissue if rows are
 * ever hard-deleted (a MAX()+1 scheme would not be).
 *
 * Sign convention: amounts are stored the way the app models them —
 * negative = expense. Plaid's convention is the opposite; ingestPlaidResult
 * negates exactly once at the boundary.
 *
 * Logging policy (SECURITY_POLICY §8): counts and UUIDs only. Never log
 * descriptions, merchant names, or amounts.
 */

import { randomUUID } from 'node:crypto';
import db from '../db.js';

const NOW_SQL = `strftime('%Y-%m-%dT%H:%M:%fZ','now')`;

// ---------------------------------------------------------------------------
// change_seq counter

const nextSeqStmt = db.prepare(
  'UPDATE transactions_sync_state SET last_seq = last_seq + 1 WHERE id = 1 RETURNING last_seq'
);
const currentSeqStmt = db.prepare(
  'SELECT last_seq FROM transactions_sync_state WHERE id = 1'
);

export function nextChangeSeq() {
  return nextSeqStmt.get().last_seq;
}

export function currentChangeSeq() {
  return currentSeqStmt.get().last_seq;
}

// ---------------------------------------------------------------------------
// Validation helpers. Strict on shape, no PII in error strings.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const SOURCES = new Set(['plaid', 'import', 'manual']);

export function isUuid(v) {
  return typeof v === 'string' && UUID_RE.test(v);
}

function isDateYMD(v) {
  if (typeof v !== 'string' || !DATE_RE.test(v)) return false;
  return !Number.isNaN(Date.parse(`${v}T00:00:00Z`));
}

function isBoolish(v) {
  return v === true || v === false || v === 0 || v === 1;
}

function asInt01(v) {
  return v === true || v === 1 ? 1 : 0;
}

function optionalString(v, maxLen) {
  return v == null || (typeof v === 'string' && v.length <= maxLen);
}

/** Validate one row for POST /api/transactions. Returns an error string or null. */
export function validateNewTransaction(t) {
  if (t == null || typeof t !== 'object' || Array.isArray(t)) return 'not an object';
  if (!isUuid(t.id)) return 'invalid id';
  if (!isDateYMD(t.date)) return 'invalid date';
  if (typeof t.description !== 'string' || t.description.length === 0 || t.description.length > 500)
    return 'invalid description';
  if (!optionalString(t.merchant, 200)) return 'invalid merchant';
  if (typeof t.amount !== 'number' || !Number.isFinite(t.amount)) return 'invalid amount';
  if (t.category_id != null && !isUuid(t.category_id)) return 'invalid category_id';
  if (t.is_manually_categorized != null && !isBoolish(t.is_manually_categorized))
    return 'invalid is_manually_categorized';
  if (!optionalString(t.external_id, 100)) return 'invalid external_id';
  if (t.imported_file_id != null && !isUuid(t.imported_file_id)) return 'invalid imported_file_id';
  if (typeof t.source !== 'string' || !SOURCES.has(t.source)) return 'invalid source';
  if (t.is_deleted != null && !isBoolish(t.is_deleted)) return 'invalid is_deleted';
  return null;
}

const PATCHABLE = new Set([
  'description',
  'merchant',
  'amount',
  'date',
  'category_id',
  'is_manually_categorized',
  'imported_file_id',
  'is_deleted',
]);

/**
 * Validate a PATCH body. Returns { error } or { patch } with normalized
 * values. month is always derived from date — never directly patchable.
 */
export function validatePatch(raw) {
  if (raw == null || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'not an object' };
  const keys = Object.keys(raw);
  if (keys.length === 0) return { error: 'empty patch' };
  const patch = {};
  for (const key of keys) {
    if (!PATCHABLE.has(key)) return { error: `unknown field ${key}` };
    const v = raw[key];
    switch (key) {
      case 'description':
        if (typeof v !== 'string' || v.length === 0 || v.length > 500) return { error: 'invalid description' };
        patch.description = v;
        break;
      case 'merchant':
        if (!optionalString(v, 200)) return { error: 'invalid merchant' };
        patch.merchant = v ?? null;
        break;
      case 'amount':
        if (typeof v !== 'number' || !Number.isFinite(v)) return { error: 'invalid amount' };
        patch.amount = v;
        break;
      case 'date':
        if (!isDateYMD(v)) return { error: 'invalid date' };
        patch.date = v;
        patch.month = v.slice(0, 7);
        break;
      case 'category_id':
        if (v != null && !isUuid(v)) return { error: 'invalid category_id' };
        patch.category_id = v ?? null;
        break;
      case 'is_manually_categorized':
        if (!isBoolish(v)) return { error: 'invalid is_manually_categorized' };
        patch.is_manually_categorized = asInt01(v);
        break;
      case 'imported_file_id':
        if (v != null && !isUuid(v)) return { error: 'invalid imported_file_id' };
        patch.imported_file_id = v ?? null;
        break;
      case 'is_deleted':
        if (!isBoolish(v)) return { error: 'invalid is_deleted' };
        patch.is_deleted = asInt01(v);
        break;
    }
  }
  return { patch };
}

// ---------------------------------------------------------------------------
// Wire format — booleans out, everything else as stored.

function toWire(row) {
  return {
    ...row,
    is_manually_categorized: !!row.is_manually_categorized,
    is_deleted: !!row.is_deleted,
  };
}

// ---------------------------------------------------------------------------
// Reads

const listStmt = db.prepare(
  'SELECT * FROM transactions WHERE change_seq > ? ORDER BY change_seq ASC LIMIT ?'
);

/** Page of changes after sinceSeq. Fetches limit+1 to compute has_more exactly. */
export function listChanges(sinceSeq, limit) {
  const rows = listStmt.all(sinceSeq, limit + 1);
  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  const nextSeq = page.length > 0 ? page[page.length - 1].change_seq : sinceSeq;
  return { changes: page.map(toWire), nextSeq, hasMore };
}

// ---------------------------------------------------------------------------
// Writes

const idExistsStmt = db.prepare('SELECT 1 FROM transactions WHERE id = ?');
const externalExistsStmt = db.prepare('SELECT 1 FROM transactions WHERE external_id = ?');
const getByIdStmt = db.prepare('SELECT * FROM transactions WHERE id = ?');
const getByExternalStmt = db.prepare('SELECT * FROM transactions WHERE external_id = ?');

const insertStmt = db.prepare(`
  INSERT INTO transactions (
    id, external_id, account_id, item_id, date, month, description, merchant,
    amount, category_id, is_manually_categorized, plaid_category,
    plaid_category_detailed, imported_file_id, source, is_deleted, change_seq
  ) VALUES (
    @id, @external_id, @account_id, @item_id, @date, @month, @description, @merchant,
    @amount, @category_id, @is_manually_categorized, @plaid_category,
    @plaid_category_detailed, @imported_file_id, @source, @is_deleted, @change_seq
  )
`);

function insertRow(fields) {
  insertStmt.run({
    external_id: null,
    account_id: null,
    item_id: null,
    merchant: null,
    category_id: null,
    is_manually_categorized: 0,
    plaid_category: null,
    plaid_category_detailed: null,
    imported_file_id: null,
    source: 'manual',
    is_deleted: 0,
    ...fields,
    change_seq: nextChangeSeq(),
  });
}

/**
 * Idempotent bulk insert for client-created rows (manual entries, file
 * imports, and the one-time seed). Rows whose id or external_id already
 * exist are skipped, so interrupted seeds can simply be retried.
 * Validation is the caller's job (route layer).
 */
export const insertMany = db.transaction((rows) => {
  let inserted = 0;
  let skipped = 0;
  for (const t of rows) {
    // Swift uppercases UUID strings; the server generates lowercase.
    // Normalize before the idempotency checks or retries would duplicate.
    const id = t.id.toLowerCase();
    if (idExistsStmt.get(id)) {
      skipped++;
      continue;
    }
    if (t.external_id != null && externalExistsStmt.get(t.external_id)) {
      skipped++;
      continue;
    }
    insertRow({
      id,
      external_id: t.external_id ?? null,
      date: t.date,
      month: t.date.slice(0, 7),
      description: t.description,
      merchant: t.merchant ?? null,
      amount: t.amount,
      category_id: t.category_id ? t.category_id.toLowerCase() : null,
      is_manually_categorized: asInt01(t.is_manually_categorized),
      imported_file_id: t.imported_file_id ? t.imported_file_id.toLowerCase() : null,
      source: t.source,
      is_deleted: asInt01(t.is_deleted),
    });
    inserted++;
  }
  return { inserted, skipped, maxChangeSeq: currentChangeSeq() };
});

/**
 * Apply a validated patch to one row. Returns the updated wire row, or
 * null if the id is unknown. Always stamps updated_at + a fresh change_seq.
 */
export function applyPatch(rawId, patch) {
  const id = rawId.toLowerCase();
  const row = getByIdStmt.get(id);
  if (!row) return null;
  // patch keys are guaranteed column-safe: they only ever come from
  // validatePatch's whitelist. Values are bound as parameters.
  const setClause = Object.keys(patch)
    .map((c) => `${c} = @${c}`)
    .join(', ');
  db.prepare(
    `UPDATE transactions SET ${setClause}, updated_at = ${NOW_SQL}, change_seq = @change_seq WHERE id = @id`
  ).run({ ...patch, change_seq: nextChangeSeq(), id });
  return toWire(getByIdStmt.get(id));
}

/** Batch of {id, patch} ops in one transaction. Patches must be pre-validated. */
export const applyBatch = db.transaction((ops) => {
  let updated = 0;
  const notFound = [];
  for (const op of ops) {
    if (applyPatch(op.id, op.patch)) updated++;
    else notFound.push(op.id);
  }
  return { updated, notFound };
});

// ---------------------------------------------------------------------------
// Plaid ingestion — the server consumes the Plaid stream ONCE, here.

const tombstoneByExternalStmt = db.prepare(`
  UPDATE transactions SET is_deleted = 1, updated_at = ${NOW_SQL}, change_seq = ?
  WHERE external_id = ? AND is_deleted = 0
`);

/**
 * Fold one item's /transactions/sync result (already fully paginated and
 * buffered by the caller) into the table, inside a single transaction.
 *
 * - added: skip pending; skip already-known external_ids (including
 *   tombstoned ones — a user deletion must not resurrect).
 * - modified: amount/date/month always update; description/merchant only
 *   when the row was never manually categorized (mirrors the app's
 *   updateTransactionByExternalId protection). Rows we never stored
 *   (e.g. modified-while-pending) insert if no longer pending.
 * - removed: tombstone, never hard-delete.
 *
 * Returns counts only — callers must not log transaction contents.
 */
export const ingestPlaidResult = db.transaction((item, result) => {
  const counts = { added: 0, addedSkipped: 0, pendingSkipped: 0, modified: 0, removed: 0 };

  for (const txn of result.added) {
    if (txn.pending) {
      counts.pendingSkipped++;
      continue;
    }
    if (externalExistsStmt.get(txn.transaction_id)) {
      counts.addedSkipped++;
      continue;
    }
    insertPlaidRow(item, txn);
    counts.added++;
  }

  for (const txn of result.modified) {
    if (txn.pending) {
      counts.pendingSkipped++;
      continue;
    }
    const existing = getByExternalStmt.get(txn.transaction_id);
    if (!existing) {
      insertPlaidRow(item, txn);
      counts.added++;
      continue;
    }
    const seq = nextChangeSeq();
    if (existing.is_manually_categorized) {
      db.prepare(
        `UPDATE transactions SET amount = ?, date = ?, month = ?, updated_at = ${NOW_SQL}, change_seq = ? WHERE id = ?`
      ).run(-txn.amount, txn.date, txn.date.slice(0, 7), seq, existing.id);
    } else {
      db.prepare(
        `UPDATE transactions SET amount = ?, date = ?, month = ?, description = ?, merchant = ?,
         plaid_category = ?, plaid_category_detailed = ?, updated_at = ${NOW_SQL}, change_seq = ? WHERE id = ?`
      ).run(
        -txn.amount,
        txn.date,
        txn.date.slice(0, 7),
        txn.merchant_name || txn.name,
        txn.merchant_name || null,
        txn.category || null,
        txn.category_detailed || null,
        seq,
        existing.id
      );
    }
    counts.modified++;
  }

  for (const removed of result.removed) {
    const r = tombstoneByExternalStmt.run(nextChangeSeq(), removed.transaction_id);
    if (r.changes > 0) counts.removed++;
  }

  return counts;
});

function insertPlaidRow(item, txn) {
  insertRow({
    id: randomUUID(),
    external_id: txn.transaction_id,
    account_id: txn.account_id ?? null,
    item_id: item.id,
    date: txn.date,
    month: txn.date.slice(0, 7),
    description: txn.merchant_name || txn.name,
    merchant: txn.merchant_name || null,
    amount: -txn.amount,
    plaid_category: txn.category || null,
    plaid_category_detailed: txn.category_detailed || null,
    source: 'plaid',
  });
}
