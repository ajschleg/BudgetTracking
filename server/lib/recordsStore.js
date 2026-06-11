/**
 * Generic record store — server side of Phase 3 (everything on the mini).
 *
 * Five record types sync through here as OPAQUE JSON payloads: the server
 * orders them on a change_seq feed and answers cursor pulls; it never
 * parses a payload. Dedup/merge semantics (category name matching, LWW,
 * id remapping) live in the Swift clients where the models are understood.
 *
 * Convergence contract (same as transactionsStore):
 * - change_seq comes from a counter table, never MAX()+1.
 * - A bulk upsert whose payload + is_deleted are byte-identical to the
 *   stored row is a seq-silent no-op — clients re-push rows they merely
 *   pulled (clock skew makes ownership ambiguous), and a seq bump per
 *   no-op would ping-pong updates between devices forever.
 *
 * Logging policy (SECURITY_POLICY §8): counts and UUIDs only. Payloads
 * carry budget names and bank-profile details — never log them.
 */

import db from '../db.js';

const NOW_SQL = `strftime('%Y-%m-%dT%H:%M:%fZ','now')`;

export const RECORD_TYPES = new Set([
  'budget_category',
  'categorization_rule',
  'monthly_snapshot',
  'bank_profile',
  'imported_file',
]);

export const MAX_PAYLOAD_BYTES = 65536;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ---------------------------------------------------------------------------
// change_seq counter

const nextSeqStmt = db.prepare(
  'UPDATE records_sync_state SET last_seq = last_seq + 1 WHERE id = 1 RETURNING last_seq'
);
const currentSeqStmt = db.prepare(
  'SELECT last_seq FROM records_sync_state WHERE id = 1'
);

function nextChangeSeq() {
  return nextSeqStmt.get().last_seq;
}

export function currentChangeSeq() {
  return currentSeqStmt.get().last_seq;
}

// ---------------------------------------------------------------------------
// Validation

/** Validate one row for POST /api/records/bulk. Returns error string or null. */
export function validateRecord(r) {
  if (r == null || typeof r !== 'object' || Array.isArray(r)) return 'not an object';
  if (typeof r.record_type !== 'string' || !RECORD_TYPES.has(r.record_type))
    return 'invalid record_type';
  if (typeof r.id !== 'string' || !UUID_RE.test(r.id)) return 'invalid id';
  if (typeof r.payload !== 'string' || r.payload.length === 0) return 'invalid payload';
  if (Buffer.byteLength(r.payload, 'utf8') > MAX_PAYLOAD_BYTES) return 'payload too large';
  if (r.is_deleted != null && r.is_deleted !== true && r.is_deleted !== false
      && r.is_deleted !== 0 && r.is_deleted !== 1) return 'invalid is_deleted';
  return null;
}

function asInt01(v) {
  return v === true || v === 1 ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Wire format

function toWire(row) {
  return { ...row, is_deleted: !!row.is_deleted };
}

// ---------------------------------------------------------------------------
// Reads

const listStmt = db.prepare(
  'SELECT * FROM server_records WHERE change_seq > ? ORDER BY change_seq ASC LIMIT ?'
);

/** Page of changes after sinceSeq; limit+1 fetch gives an exact has_more. */
export function listChanges(sinceSeq, limit) {
  const rows = listStmt.all(sinceSeq, limit + 1);
  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  const nextSeq = page.length > 0 ? page[page.length - 1].change_seq : sinceSeq;
  return { changes: page.map(toWire), nextSeq, hasMore };
}

// ---------------------------------------------------------------------------
// Writes

const getStmt = db.prepare(
  'SELECT * FROM server_records WHERE record_type = ? AND id = ?'
);
const insertStmt = db.prepare(`
  INSERT INTO server_records (record_type, id, payload, is_deleted, change_seq)
  VALUES (@record_type, @id, @payload, @is_deleted, @change_seq)
`);
const updateStmt = db.prepare(`
  UPDATE server_records
  SET payload = @payload, is_deleted = @is_deleted,
      updated_at = ${NOW_SQL}, change_seq = @change_seq
  WHERE record_type = @record_type AND id = @id
`);

/**
 * Idempotent bulk UPSERT. Rows must be pre-validated (route layer).
 * New (type,id) → insert; byte-identical payload + is_deleted → seq-silent
 * skip; anything else → replace with a fresh seq + updated_at.
 */
export const bulkUpsert = db.transaction((rows) => {
  let upserted = 0;
  let skipped = 0;
  for (const r of rows) {
    const id = r.id.toLowerCase(); // Swift uppercases UUIDs
    const isDeleted = asInt01(r.is_deleted);
    const existing = getStmt.get(r.record_type, id);
    if (existing && existing.payload === r.payload && existing.is_deleted === isDeleted) {
      skipped++;
      continue;
    }
    const params = {
      record_type: r.record_type,
      id,
      payload: r.payload,
      is_deleted: isDeleted,
      change_seq: nextChangeSeq(),
    };
    if (existing) {
      updateStmt.run(params);
    } else {
      insertStmt.run(params);
    }
    upserted++;
  }
  return { upserted, skipped };
});
