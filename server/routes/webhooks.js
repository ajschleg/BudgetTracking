import { Router } from 'express';
import { createHash } from 'crypto';
import * as jose from 'jose';
import db from '../db.js';
import { decrypt } from '../lib/crypto.js';
import { requireAppToken } from '../middleware/auth.js';

/**
 * Plaid webhook receiver with signature verification.
 *
 * Plaid sends POST requests with a JWT in the Plaid-Verification header.
 * We verify the JWT using Plaid's public key (fetched via
 * /webhook_verification_key/get and cached), then compare the SHA-256
 * hash of the request body against the JWT's request_body_sha256 claim.
 */

export function createWebhookRouter(plaidClient) {
  const router = Router();
  const keyCache = new Map(); // kid -> JWK

  /**
   * Fetch and cache a webhook verification key from Plaid.
   */
  async function getVerificationKey(kid) {
    if (keyCache.has(kid)) {
      return keyCache.get(kid);
    }
    const response = await plaidClient.webhookVerificationKeyGet({ key_id: kid });
    const key = response.data.key;
    keyCache.set(kid, key);
    return key;
  }

  /**
   * Verify the Plaid-Verification JWT against the raw request body.
   * Returns true if valid, false if verification fails.
   */
  async function verifyWebhook(rawBody, jwtToken) {
    try {
      // Decode header without verification to get the kid
      const decodedHeader = jose.decodeProtectedHeader(jwtToken);

      if (decodedHeader.alg !== 'ES256') {
        console.warn('[webhook] Unexpected JWT algorithm:', decodedHeader.alg);
        return false;
      }

      // Fetch the verification key from Plaid
      const jwk = await getVerificationKey(decodedHeader.kid);
      const keyLike = await jose.importJWK(jwk, 'ES256');

      // Verify signature + enforce max 5 minute age
      const { payload } = await jose.jwtVerify(jwtToken, keyLike, {
        maxTokenAge: '5 min',
      });

      // Compare body hash
      const bodyHash = createHash('sha256').update(rawBody).digest('hex');
      if (bodyHash !== payload.request_body_sha256) {
        console.warn('[webhook] Body hash mismatch');
        return false;
      }

      return true;
    } catch (error) {
      console.error('[webhook] Verification error:', error.message);
      return false;
    }
  }

  /**
   * POST /webhook — Plaid's webhook receiver.
   *
   * This endpoint accepts raw JSON (needed for signature verification)
   * and must be publicly reachable at the URL registered in
   * /link/token/create or the Plaid Dashboard.
   */
  router.post('/', async (req, res) => {
    // req.rawBody is populated by the express.json verify hook (see server.js)
    const rawBody = req.rawBody || JSON.stringify(req.body);
    const jwtToken = req.headers['plaid-verification'];
    const env = process.env.PLAID_ENV || 'sandbox';

    let verified = false;
    if (jwtToken) {
      verified = await verifyWebhook(rawBody, jwtToken);
    }

    // Reject unsigned / failed-verification webhooks in any non-sandbox
    // environment. Sandbox allows unsigned to support local testing
    // without a real Plaid → server delivery path, but production and
    // development webhooks must be signed by Plaid.
    if (!verified) {
      if (env !== 'sandbox') {
        console.warn(
          `[webhook] Rejecting unverified webhook in ${env} (no valid Plaid-Verification JWT)`
        );
        return res.status(401).json({ error: 'Unverified webhook' });
      }
      if (!jwtToken) {
        console.warn('[webhook] No Plaid-Verification header — sandbox test mode');
      }
    }

    const payload = req.body;
    const { webhook_type, webhook_code, item_id } = payload;

    console.log(
      `[webhook] Received ${webhook_type}/${webhook_code} for item ${item_id} (verified: ${verified})`
    );

    // Persist the event for inspection and debugging
    db.prepare(`
      INSERT INTO webhook_events (webhook_type, webhook_code, item_id, payload, verified)
      VALUES (?, ?, ?, ?, ?)
    `).run(
      webhook_type || 'UNKNOWN',
      webhook_code || 'UNKNOWN',
      item_id || null,
      JSON.stringify(payload),
      verified ? 1 : 0
    );

    // Route the webhook to handlers based on type and code
    try {
      await handleWebhook(plaidClient, payload);
    } catch (error) {
      console.error('[webhook] Handler error:', error.message);
    }

    // Always return 200 quickly — Plaid retries on non-2xx
    res.json({ received: true });
  });

  /**
   * GET /webhook/events — Recent webhook events (for debugging / UI).
   *
   * Protected by the same X-App-Token as /api/*. Historical payloads
   * can contain item_ids, institution names, and error details that
   * do not belong on a public ngrok URL.
   */
  router.get('/events', requireAppToken, (_req, res) => {
    const events = db
      .prepare(
        `SELECT id, webhook_type, webhook_code, item_id, verified, received_at, payload
         FROM webhook_events
         ORDER BY received_at DESC
         LIMIT 50`
      )
      .all();
    res.json({ events });
  });

  /**
   * POST /webhook/fire — Sandbox helper that fires a webhook on demand.
   *
   * Body: { item_id: <local item_id>, webhook_code: "NEW_ACCOUNTS_AVAILABLE" }
   *
   * Uses /sandbox/item/fire_webhook under the hood. Gated to sandbox
   * only — registering this route in non-sandbox environments would
   * fail on the Plaid side anyway (sandbox endpoints are 400 on
   * development/production), so we return a clear 404 upfront instead
   * of surfacing a confusing Plaid error.
   */
  if ((process.env.PLAID_ENV || 'sandbox') === 'sandbox') {
    // Also gated by the app-token — this endpoint can trigger real
    // Plaid webhooks against any linked item, so random ngrok callers
    // must not be able to hit it.
    router.post('/fire', requireAppToken, async (req, res) => {
      const {
        item_id,
        webhook_code = 'NEW_ACCOUNTS_AVAILABLE',
        webhook_type,
      } = req.body;

      if (!item_id) {
        return res.status(400).json({ error: 'item_id is required' });
      }

      const item = db.prepare('SELECT * FROM plaid_items WHERE id = ?').get(item_id);
      if (!item) {
        return res.status(404).json({ error: 'Item not found' });
      }

      try {
        const request = {
          access_token: decrypt(item.access_token),
          webhook_code,
        };
        if (webhook_type) {
          request.webhook_type = webhook_type;
        }

        const response = await plaidClient.sandboxItemFireWebhook(request);
        res.json({
          webhook_fired: response.data.webhook_fired,
          request_id: response.data.request_id,
        });
      } catch (error) {
        console.error(
          '[webhook] fire error:',
          error.response?.data || error.message
        );
        res.status(500).json({
          error: error.response?.data?.error_message || error.message,
        });
      }
    });
  } else {
    // In development/production, expose the route but return a clear
    // 410 Gone so anyone hitting it from a test script sees exactly
    // why (instead of a generic 404 that looks like a typo). Still
    // gated by app-token auth so the 410 is only exposed to
    // legitimate callers and unauthenticated probes get 401 first.
    router.post('/fire', requireAppToken, (_req, res) => {
      res.status(410).json({
        error: `Sandbox endpoints are not available in PLAID_ENV=${process.env.PLAID_ENV}`,
      });
    });
  }

  return router;
}

/**
 * Handle a verified webhook event. Fan out to product-specific handlers.
 */
async function handleWebhook(plaidClient, payload) {
  const { webhook_type, webhook_code, item_id } = payload;

  // Find the local item record via the Plaid item_id
  const item = db.prepare('SELECT * FROM plaid_items WHERE item_id = ?').get(item_id);
  if (!item) {
    console.warn(`[webhook] Unknown item_id: ${item_id}`);
    return;
  }

  switch (`${webhook_type}:${webhook_code}`) {
    case 'ITEM:NEW_ACCOUNTS_AVAILABLE':
      // Per Plaid docs, NEW_ACCOUNTS_AVAILABLE means we should prompt
      // the user to re-enter Link in update mode with
      // account_selection_enabled=true so they can opt-in the new
      // accounts. We flag the item the same way as ITEM_LOGIN_REQUIRED
      // but with a distinct reason so the UI can style it differently
      // (informational, not urgent). We still call accountsGet as a
      // best-effort preview so the server knows what's available.
      markNeedsUpdate(item.id, 'NEW_ACCOUNTS_AVAILABLE');
      await handleNewAccountsAvailable(plaidClient, item);
      break;

    case 'TRANSACTIONS:SYNC_UPDATES_AVAILABLE':
    case 'TRANSACTIONS:DEFAULT_UPDATE':
      handleTransactionsUpdate(item, payload);
      break;

    case 'TRANSACTIONS:INITIAL_UPDATE':
      // Legacy (/transactions/get) webhook — we use /transactions/sync,
      // but some institutions still send this. Treat it like a generic
      // update: mark pending and note initial completion.
      markPendingUpdate(item.id, { initial: true });
      break;

    case 'TRANSACTIONS:HISTORICAL_UPDATE':
      // Legacy historical-completion signal for /transactions/get. Mark
      // historical complete so the UI can drop any "still backfilling"
      // messaging.
      markPendingUpdate(item.id, { historical: true });
      break;

    case 'ITEM:PENDING_DISCONNECT':
    case 'ITEM:PENDING_EXPIRATION':
    case 'ITEM:LOGIN_REPAIRED':
      // LOGIN_REPAIRED is Plaid telling us an item that previously
      // needed update mode has fixed itself (usually because the user
      // re-authenticated at the bank directly). Clear the flag.
      if (webhook_code === 'LOGIN_REPAIRED') {
        clearNeedsUpdate(item.id);
      } else {
        markNeedsUpdate(item.id, webhook_code);
      }
      console.warn(
        `[webhook] Item ${item_id}: ${webhook_code}`,
        payload.error || ''
      );
      break;

    case 'ITEM:ERROR':
      // ITEM/ERROR payloads carry a specific error_code. Only treat
      // ITEM_LOGIN_REQUIRED as needing update mode — other item errors
      // (rate limits, bank outages) resolve themselves.
      if (payload.error?.error_code === 'ITEM_LOGIN_REQUIRED') {
        markNeedsUpdate(item.id, 'ITEM_LOGIN_REQUIRED');
      }
      console.warn(
        `[webhook] Item ${item_id} error:`,
        payload.error
      );
      break;

    case 'ITEM:USER_PERMISSION_REVOKED':
    case 'ITEM:USER_ACCOUNT_REVOKED':
      // Per Plaid launch checklist: "Listen for revocation webhooks
      // to prevent unauthorized transfers." The user has revoked
      // access at their bank (USER_ACCOUNT_REVOKED) or at Plaid
      // Portal (USER_PERMISSION_REVOKED). The access token is now
      // invalid server-side; we must stop syncing and surface a
      // clear state to the user.
      await handleUserRevocation(plaidClient, item, webhook_code);
      break;

    default:
      console.log(`[webhook] Unhandled: ${webhook_type}/${webhook_code}`);
  }
}

/**
 * Handle a TRANSACTIONS:SYNC_UPDATES_AVAILABLE webhook.
 *
 * Plaid includes two flags we care about:
 *   - initial_update_complete: the fast 30-day sync finished
 *   - historical_update_complete: the full backfill finished
 *
 * We persist both flags per item and mark pending_update_available so
 * the app can show "new transactions waiting" and pull them on its next
 * /api/transactions/sync call.
 */
function handleTransactionsUpdate(item, payload) {
  const initial = payload.initial_update_complete === true;
  const historical = payload.historical_update_complete === true;
  markPendingUpdate(item.id, { initial, historical });

  const flags = [];
  if (initial) flags.push('initial_complete');
  if (historical) flags.push('historical_complete');
  console.log(
    `[webhook] SYNC_UPDATES_AVAILABLE for ${item.item_id}` +
      (flags.length ? ` (${flags.join(', ')})` : '')
  );
}

/**
 * Mark an item as needing update mode (user re-auth). Called from the
 * webhook router on ITEM_LOGIN_REQUIRED, PENDING_EXPIRATION,
 * PENDING_DISCONNECT, and from the API layer when a Plaid call returns
 * the ITEM_LOGIN_REQUIRED error code.
 *
 * Exported so plaid routes can call it when a live /transactions/sync
 * surfaces the error before the webhook arrives.
 */
export function markNeedsUpdate(localItemId, reason) {
  db.prepare(`
    UPDATE plaid_items SET
      needs_update = 1,
      needs_update_reason = ?,
      needs_update_detected_at = datetime('now')
    WHERE id = ?
  `).run(reason, localItemId);
}

/** Clear the needs_update flag (e.g., after successful update-mode link). */
export function clearNeedsUpdate(localItemId) {
  db.prepare(`
    UPDATE plaid_items SET
      needs_update = 0,
      needs_update_reason = NULL,
      needs_update_detected_at = NULL
    WHERE id = ?
  `).run(localItemId);
}

/**
 * Flip per-item lifecycle flags without clobbering the cursor. The flags
 * are sticky (once true, stay true) because Plaid will not re-send the
 * completion webhook for an item.
 */
function markPendingUpdate(localItemId, { initial = false, historical = false } = {}) {
  db.prepare(`
    UPDATE sync_cursors SET
      pending_update_available = 1,
      initial_update_complete = CASE WHEN ? THEN 1 ELSE initial_update_complete END,
      historical_update_complete = CASE WHEN ? THEN 1 ELSE historical_update_complete END
    WHERE plaid_item_id = ?
  `).run(initial ? 1 : 0, historical ? 1 : 0, localItemId);
}

/**
 * Handle a user-initiated revocation (USER_PERMISSION_REVOKED or
 * USER_ACCOUNT_REVOKED). Per the Plaid launch checklist we must:
 *
 * 1. Stop using the access token immediately (it is invalid anyway).
 * 2. Call /item/remove best-effort to clean up Plaid's side.
 * 3. Delete our local copies of the item + accounts + webhook events.
 *
 * Same flow as a user-initiated disconnect from Settings, just
 * triggered by Plaid instead of by us.
 */
async function handleUserRevocation(plaidClient, item, webhookCode) {
  console.warn(
    `[webhook] Honoring ${webhookCode} for item ${item.item_id} — removing item`
  );

  try {
    await plaidClient.itemRemove({ access_token: decrypt(item.access_token) });
  } catch (error) {
    // Already-invalid tokens throw here — that is fine, we still
    // want to drop local state.
    console.warn(
      '[webhook] itemRemove after revocation:',
      error.response?.data?.error_code || error.message
    );
  }

  db.prepare('DELETE FROM plaid_items WHERE id = ?').run(item.id);
  db.prepare('DELETE FROM webhook_events WHERE item_id = ? AND id < ?').run(
    item.item_id,
    Number.MAX_SAFE_INTEGER
  );
  console.log(`[webhook] Revocation cleanup complete for ${item.item_id}`);
}

/**
 * NEW_ACCOUNTS_AVAILABLE: user added accounts to an existing item.
 * Fetch the current account list and upsert any new ones.
 */
async function handleNewAccountsAvailable(plaidClient, item) {
  const response = await plaidClient.accountsGet({ access_token: decrypt(item.access_token) });
  const accounts = response.data.accounts;

  const insertAccount = db.prepare(`
    INSERT OR IGNORE INTO plaid_accounts (id, plaid_item_id, plaid_account_id, name, official_name, type, subtype, mask)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  let inserted = 0;
  for (const account of accounts) {
    const result = insertAccount.run(
      crypto.randomUUID(),
      item.id,
      account.account_id,
      account.name,
      account.official_name,
      account.type,
      account.subtype,
      account.mask
    );
    if (result.changes > 0) inserted++;
  }

  console.log(
    `[webhook] NEW_ACCOUNTS_AVAILABLE: processed ${accounts.length} accounts (${inserted} new) for item ${item.item_id}`
  );
}
