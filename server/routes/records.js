/**
 * App-facing REST API for the generic record store (Phase 3: budget
 * categories, categorization rules, monthly snapshots, bank profiles,
 * imported-file metadata — opaque JSON payloads, see lib/recordsStore.js).
 *
 * Mounted under /api after the plaid + transactions routers; inherits the
 * single requireAppToken + apiLimiter chain from server.js (SECURITY_POLICY
 * §3/§6 — and never a second limiter: middleware repeated per-router counts
 * requests twice and halves the real budget).
 */

import express from 'express';
import {
  listChanges,
  bulkUpsert,
  validateRecord,
} from '../lib/recordsStore.js';
import { logAndSanitize } from '../lib/errors.js';

const router = express.Router();

const MAX_PAGE = 500;
const MAX_BATCH = 250;

// GET /api/records/changes?since=<seq>&limit=<n>
router.get('/records/changes', (req, res) => {
  try {
    const since = Number.parseInt(req.query.since ?? '0', 10);
    if (!Number.isInteger(since) || since < 0) {
      return res.status(400).json({ error: 'invalid since' });
    }
    let limit = Number.parseInt(req.query.limit ?? `${MAX_PAGE}`, 10);
    if (!Number.isInteger(limit) || limit < 1) {
      return res.status(400).json({ error: 'invalid limit' });
    }
    limit = Math.min(limit, MAX_PAGE);

    const { changes, nextSeq, hasMore } = listChanges(since, limit);
    res.json({ changes, next_seq: nextSeq, has_more: hasMore });
  } catch (error) {
    res.status(500).json({ error: logAndSanitize('records/changes', error) });
  }
});

// POST /api/records/bulk — idempotent upsert; the push side of record sync.
router.post('/records/bulk', (req, res) => {
  try {
    const rows = req.body?.records;
    if (!Array.isArray(rows) || rows.length === 0) {
      return res.status(400).json({ error: 'records array required' });
    }
    if (rows.length > MAX_BATCH) {
      return res.status(400).json({ error: `too many records (max ${MAX_BATCH})` });
    }
    for (let i = 0; i < rows.length; i++) {
      const problem = validateRecord(rows[i]);
      if (problem) {
        return res.status(400).json({ error: `invalid record at index ${i}: ${problem}` });
      }
    }

    const { upserted, skipped } = bulkUpsert(rows);
    console.log(`[records] bulk: ${upserted} upserted, ${skipped} skipped`);
    res.json({ upserted, skipped });
  } catch (error) {
    res.status(500).json({ error: logAndSanitize('records/bulk', error) });
  }
});

export default router;
