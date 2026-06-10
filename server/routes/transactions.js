/**
 * App-facing REST API for the server-authoritative transaction store.
 *
 * Mounted under /api AFTER routes/plaid.js, so the plaid router's
 * /transactions/sync and /transactions/status match first; everything
 * here uses distinct paths plus a UUID-shape guard on :id routes.
 *
 * Auth + rate limiting are inherited from the /api mount (requireAppToken,
 * apiLimiter) — see server.js. Per SECURITY_POLICY §4 every body field is
 * validated before touching the DB, and error responses never echo row
 * contents (index numbers only).
 */

import express from 'express';
import {
  listChanges,
  insertMany,
  applyPatch,
  applyBatch,
  validateNewTransaction,
  validatePatch,
  isUuid,
} from '../lib/transactionsStore.js';
import { logAndSanitize } from '../lib/errors.js';

const router = express.Router();

const MAX_PAGE = 500;
const MAX_BATCH = 250;

// GET /api/transactions/changes?since=<seq>&limit=<n>
// The pull side of device sync: everything after the client's cursor,
// in change_seq order. Clients persist next_seq and loop while has_more.
router.get('/transactions/changes', (req, res) => {
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
    res.status(500).json({ error: logAndSanitize('transactions/changes', error) });
  }
});

// POST /api/transactions — bulk create (manual entries, file imports, and
// the one-time seed). Idempotent: rows whose id or external_id already
// exist are skipped, so retries are always safe.
router.post('/transactions', (req, res) => {
  try {
    const rows = req.body?.transactions;
    if (!Array.isArray(rows) || rows.length === 0) {
      return res.status(400).json({ error: 'transactions array required' });
    }
    if (rows.length > MAX_BATCH) {
      return res.status(400).json({ error: `too many transactions (max ${MAX_BATCH})` });
    }
    for (let i = 0; i < rows.length; i++) {
      const problem = validateNewTransaction(rows[i]);
      if (problem) {
        return res.status(400).json({ error: `invalid transaction at index ${i}: ${problem}` });
      }
    }

    const { inserted, skipped, maxChangeSeq } = insertMany(rows);
    console.log(`[transactions] insert: ${inserted} new, ${skipped} skipped`);
    res.json({ inserted, skipped, max_change_seq: maxChangeSeq });
  } catch (error) {
    res.status(500).json({ error: logAndSanitize('transactions/insert', error) });
  }
});

// POST /api/transactions/batch — the push workhorse: many small edits
// (category assignments, tombstones, restores) in one request so bulk
// operations fit inside the 60 req/min rate limit.
router.post('/transactions/batch', (req, res) => {
  try {
    const ops = req.body?.ops;
    if (!Array.isArray(ops) || ops.length === 0) {
      return res.status(400).json({ error: 'ops array required' });
    }
    if (ops.length > MAX_BATCH) {
      return res.status(400).json({ error: `too many ops (max ${MAX_BATCH})` });
    }
    const validated = [];
    for (let i = 0; i < ops.length; i++) {
      const op = ops[i];
      if (op == null || !isUuid(op.id)) {
        return res.status(400).json({ error: `invalid id at index ${i}` });
      }
      const { error, patch } = validatePatch(op.patch);
      if (error) {
        return res.status(400).json({ error: `invalid patch at index ${i}: ${error}` });
      }
      validated.push({ id: op.id, patch });
    }

    const { updated, notFound } = applyBatch(validated);
    console.log(`[transactions] batch: ${updated} updated, ${notFound.length} not found`);
    res.json({ updated, not_found: notFound });
  } catch (error) {
    res.status(500).json({ error: logAndSanitize('transactions/batch', error) });
  }
});

// PATCH /api/transactions/:id — single-row edit. The UUID guard keeps this
// from ever shadowing /transactions/sync (handled by the plaid router,
// which is mounted first) or swallowing typo'd paths.
router.patch('/transactions/:id', (req, res) => {
  try {
    const { id } = req.params;
    if (!isUuid(id)) {
      return res.status(400).json({ error: 'invalid transaction id' });
    }
    const { error, patch } = validatePatch(req.body);
    if (error) {
      return res.status(400).json({ error: `invalid patch: ${error}` });
    }

    const updated = applyPatch(id, patch);
    if (!updated) {
      return res.status(404).json({ error: 'transaction not found' });
    }
    res.json({ transaction: updated });
  } catch (error) {
    res.status(500).json({ error: logAndSanitize('transactions/patch', error) });
  }
});

export default router;
