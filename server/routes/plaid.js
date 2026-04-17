import { Router } from 'express';
import { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } from 'plaid';
import { v4 as uuidv4 } from 'uuid';
import db from '../db.js';
import { markNeedsUpdate, clearNeedsUpdate } from './webhooks.js';
import { encrypt, decrypt } from '../lib/crypto.js';
import { logAndSanitize } from '../lib/errors.js';

/**
 * Extract the plaintext access_token from a plaid_items row. The value
 * is stored encrypted on disk (AES-256-GCM via ../lib/crypto.js) and
 * must be decrypted before any Plaid API call. Throws on tamper or
 * wrong key — callers should not swallow the error, since continuing
 * with a garbled token would result in confusing Plaid responses.
 */
function tokenOf(item) {
  return decrypt(item.access_token);
}

const router = Router();

// Initialize Plaid client
const plaidConfig = new Configuration({
  basePath: PlaidEnvironments[process.env.PLAID_ENV || 'sandbox'],
  baseOptions: {
    headers: {
      'PLAID-CLIENT-ID': process.env.PLAID_CLIENT_ID,
      'PLAID-SECRET': process.env.PLAID_SECRET,
      'Plaid-Version': '2020-09-14',
    },
  },
});
const plaidClient = new PlaidApi(plaidConfig);

/**
 * Resolve which OAuth redirect URI Plaid should send the user back to
 * after they complete bank OAuth.
 *
 *   1. PLAID_REDIRECT_URI env var wins if set (manual override).
 *   2. Otherwise, in sandbox we can use http://localhost:8080/oauth.html
 *      (Plaid allows HTTP for sandbox only).
 *   3. Otherwise (development/production), use the GitHub Pages URL
 *      which is HTTPS and registered in the Plaid Dashboard. The
 *      bouncer there redirects back into the macOS app via the
 *      budgettracking:// URL scheme.
 */
function resolveRedirectUri(clientSupplied) {
  if (process.env.PLAID_REDIRECT_URI) return process.env.PLAID_REDIRECT_URI;
  const env = process.env.PLAID_ENV || 'sandbox';
  if (env === 'sandbox') {
    // Honor the client's localhost URI in sandbox — supports the "change
    // the PORT in .env" flow without touching the server code.
    return clientSupplied || 'http://localhost:8080/oauth.html';
  }
  // Production / development require HTTPS per Plaid policy.
  return 'https://ajschleg.github.io/BudgetTracking/oauth.html';
}

// POST /api/link/create — Create a link token for Plaid Link
router.post('/link/create', async (req, res) => {
  try {
    const { redirect_uri } = req.body;

    const tokenRequest = {
      user: { client_user_id: 'budget-tracking-user' },
      client_name: 'BudgetTracking',
      products: [Products.Transactions],
      // Identity is added as "required if supported" so banks that do
      // not offer it (rare) can still link with Transactions-only. The
      // one-time fee is only billed on institutions that actually return
      // identity data.
      required_if_supported_products: [Products.Identity],
      country_codes: [CountryCode.Us],
      language: 'en',
      // Ask for a year of history instead of the 90-day default. Budget
      // tracking benefits from year-over-year comparisons, and backfill
      // is free (Plaid bills on sync calls, not on history depth).
      transactions: {
        days_requested: 365,
      },
    };

    // Server-resolved redirect_uri enforces HTTPS in non-sandbox envs.
    tokenRequest.redirect_uri = resolveRedirectUri(redirect_uri);

    // Register a webhook URL so Plaid can push updates to our server.
    // PLAID_WEBHOOK_URL must be publicly reachable (use ngrok or similar
    // for local development). Omit in dev to disable webhooks cleanly.
    if (process.env.PLAID_WEBHOOK_URL) {
      tokenRequest.webhook = process.env.PLAID_WEBHOOK_URL;
    }

    const response = await plaidClient.linkTokenCreate(tokenRequest);
    res.json({ link_token: response.data.link_token });
  } catch (error) {
    console.error('Error creating link token:', error.response?.data || error.message);
    res.status(500).json({ error: 'Failed to create link token' });
  }
});

// GET /api/items — List linked items (includes update-mode state)
router.get('/items', (_req, res) => {
  const items = db.prepare(`
    SELECT id, item_id, institution_id, institution_name, created_at,
           COALESCE(needs_update, 0) AS needs_update,
           needs_update_reason,
           needs_update_detected_at
    FROM plaid_items
    ORDER BY created_at DESC
  `).all();
  res.json({
    items: items.map((r) => ({
      ...r,
      needs_update: !!r.needs_update,
    })),
  });
});

// POST /api/link/create-update — Update-mode link token for re-auth.
//
// Body: {
//   item_id: <local item UUID>,
//   redirect_uri?: <oauth redirect>,
//   account_selection_enabled?: bool   // true when called in response
//                                      // to NEW_ACCOUNTS_AVAILABLE
// }
//
// Per Plaid docs, update mode:
//   - Uses the existing access_token (NOT exchanged again after)
//   - Omits the `products` array (the Item already has its products)
//   - Opens Link pre-bound to the item's institution, user just
//     re-enters credentials or reconfirms OAuth consent
//
// When account_selection_enabled=true, Link also shows the account
// picker so the user can add newly-discovered accounts (or deselect
// ones they no longer want shared).
router.post('/link/create-update', async (req, res) => {
  const {
    item_id,
    redirect_uri,
    account_selection_enabled = false,
  } = req.body || {};
  if (!item_id) {
    return res.status(400).json({ error: 'item_id is required' });
  }

  const item = db.prepare('SELECT * FROM plaid_items WHERE id = ?').get(item_id);
  if (!item) {
    return res.status(404).json({ error: 'Item not found' });
  }

  try {
    const tokenRequest = {
      user: { client_user_id: 'budget-tracking-user' },
      client_name: 'BudgetTracking',
      country_codes: [CountryCode.Us],
      language: 'en',
      access_token: tokenOf(item),
      redirect_uri: resolveRedirectUri(redirect_uri),
    };
    if (process.env.PLAID_WEBHOOK_URL) {
      tokenRequest.webhook = process.env.PLAID_WEBHOOK_URL;
    }
    if (account_selection_enabled) {
      // Plaid docs: update.account_selection_enabled lets the user
      // pick new accounts inside the existing item during update mode.
      tokenRequest.update = { account_selection_enabled: true };
    }

    const response = await plaidClient.linkTokenCreate(tokenRequest);
    res.json({ link_token: response.data.link_token });
  } catch (error) {
    console.error(
      'Error creating update link token:',
      error.response?.data || error.message
    );
    res.status(500).json({ error: 'Failed to create update link token' });
  }
});

// POST /api/items/:id/clear-update — Mark an item as healthy after the
// user completes update mode. If reconcile=true, also re-fetches the
// current account list from Plaid and upserts it so newly-selected
// accounts appear and deselected ones drop out.
router.post('/items/:id/clear-update', async (req, res) => {
  const { id } = req.params;
  const { reconcile = false } = req.body || {};
  const item = db.prepare('SELECT * FROM plaid_items WHERE id = ?').get(id);
  if (!item) return res.status(404).json({ error: 'Item not found' });

  clearNeedsUpdate(id);

  // Reconcile the account list after an account-selection update.
  // Plaid docs: "all selected accounts will be shared in the `accounts`
  // field in the onSuccess() callback from Link. Any de-selected
  // accounts will no longer be shared with you."
  if (reconcile) {
    try {
      const response = await plaidClient.accountsGet({ access_token: tokenOf(item) });
      const sharedAccountIds = new Set(response.data.accounts.map((a) => a.account_id));

      // Drop accounts that are no longer shared.
      const existing = db
        .prepare('SELECT plaid_account_id FROM plaid_accounts WHERE plaid_item_id = ?')
        .all(id);
      const deleteStmt = db.prepare(
        'DELETE FROM plaid_accounts WHERE plaid_account_id = ?'
      );
      let removedCount = 0;
      for (const row of existing) {
        if (!sharedAccountIds.has(row.plaid_account_id)) {
          deleteStmt.run(row.plaid_account_id);
          removedCount++;
        }
      }

      // Upsert current shared accounts.
      const insertStmt = db.prepare(`
        INSERT OR REPLACE INTO plaid_accounts
          (id, plaid_item_id, plaid_account_id, name, official_name, type, subtype, mask)
        VALUES (
          COALESCE((SELECT id FROM plaid_accounts WHERE plaid_account_id = ?), ?),
          ?, ?, ?, ?, ?, ?, ?
        )
      `);
      let addedCount = 0;
      for (const acct of response.data.accounts) {
        const existingRow = db
          .prepare('SELECT 1 FROM plaid_accounts WHERE plaid_account_id = ?')
          .get(acct.account_id);
        insertStmt.run(
          acct.account_id,
          uuidv4(),
          id,
          acct.account_id,
          acct.name,
          acct.official_name,
          acct.type,
          acct.subtype,
          acct.mask
        );
        if (!existingRow) addedCount++;
      }

      console.log(
        `[update-mode] Reconciled item ${id}: +${addedCount} new, -${removedCount} removed`
      );
    } catch (error) {
      console.error(
        '[update-mode] Reconcile failed:',
        error.response?.data || error.message
      );
    }
  }

  res.json({ success: true });
});

// POST /api/identity/refresh — Refresh identity data from Plaid.
//
// Body (optional): { item_id: <local item UUID> }
//
// Calls /identity/get for all linked items (or one) and updates the
// owner_name, owner_email, owner_phone, owners_json columns. Each call
// bills a one-time fee per item per Plaid pricing — we cache the result
// indefinitely since identity rarely changes. Plaid docs note that
// "Identity data rarely changes; re-fetching is typically unnecessary."
router.post('/identity/refresh', async (req, res) => {
  const { item_id } = req.body || {};

  const items = item_id
    ? db.prepare('SELECT * FROM plaid_items WHERE id = ?').all(item_id)
    : db.prepare('SELECT * FROM plaid_items').all();

  if (items.length === 0) {
    return res.json({ refreshed: [], errors: [] });
  }

  const refreshed = [];
  const errors = [];

  for (const item of items) {
    try {
      await fetchAndStoreIdentity(tokenOf(item), item.id);
      refreshed.push({ item_id: item.id, institution_name: item.institution_name });
    } catch (error) {
      errors.push({
        item_id: item.id,
        institution_name: item.institution_name,
        error: logAndSanitize(`identity/${item.id}`, error, 'Failed to refresh identity'),
      });
    }
  }

  res.json({ refreshed, errors });
});

// POST /api/items/:id/webhook — Update webhook URL on an existing item.
// Required before /sandbox/item/fire_webhook works for items created
// without a webhook URL. Body: { webhook?: string } — defaults to env.
router.post('/items/:id/webhook', async (req, res) => {
  const { id } = req.params;
  const webhook = req.body?.webhook || process.env.PLAID_WEBHOOK_URL;

  if (!webhook) {
    return res.status(400).json({
      error: 'No webhook URL provided. Set PLAID_WEBHOOK_URL or pass webhook in body.',
    });
  }

  const item = db.prepare('SELECT * FROM plaid_items WHERE id = ?').get(id);
  if (!item) {
    return res.status(404).json({ error: 'Item not found' });
  }

  try {
    await plaidClient.itemWebhookUpdate({
      access_token: tokenOf(item),
      webhook,
    });
    res.json({ success: true, webhook });
  } catch (error) {
    res.status(500).json({
      error: logAndSanitize('itemWebhookUpdate', error, 'Failed to update webhook URL'),
    });
  }
});

// POST /api/link/exchange — Exchange public token for access token
router.post('/link/exchange', async (req, res) => {
  const { public_token, institution } = req.body;
  if (!public_token) {
    return res.status(400).json({ error: 'public_token is required' });
  }

  try {
    // Exchange public token for access token
    const exchangeResponse = await plaidClient.itemPublicTokenExchange({
      public_token,
    });
    const { access_token, item_id } = exchangeResponse.data;

    // Get account details
    const accountsResponse = await plaidClient.accountsGet({ access_token });
    const accounts = accountsResponse.data.accounts;

    // Save item to DB. Access token is encrypted at rest — see
    // ../lib/crypto.js. Plaintext never touches SQLite.
    const itemId = uuidv4();
    db.prepare(`
      INSERT OR REPLACE INTO plaid_items (id, item_id, access_token, institution_id, institution_name)
      VALUES (?, ?, ?, ?, ?)
    `).run(
      itemId,
      item_id,
      encrypt(access_token),
      institution?.institution_id || null,
      institution?.name || null
    );

    // Save accounts to DB
    const insertAccount = db.prepare(`
      INSERT OR REPLACE INTO plaid_accounts (id, plaid_item_id, plaid_account_id, name, official_name, type, subtype, mask)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);

    const savedAccounts = [];
    for (const account of accounts) {
      const accountId = uuidv4();
      insertAccount.run(
        accountId,
        itemId,
        account.account_id,
        account.name,
        account.official_name,
        account.type,
        account.subtype,
        account.mask
      );
      savedAccounts.push({
        id: accountId,
        plaid_account_id: account.account_id,
        name: account.name,
        official_name: account.official_name,
        type: account.type,
        subtype: account.subtype,
        mask: account.mask,
      });
    }

    // Initialize sync cursor
    db.prepare(`
      INSERT OR REPLACE INTO sync_cursors (plaid_item_id, cursor, last_synced_at)
      VALUES (?, NULL, NULL)
    `).run(itemId);

    // Fetch identity data opportunistically. Plaid Identity bills a
    // one-time fee per item, and on-link is the natural moment to run it
    // (user is actively connecting the account, knows it is happening).
    // Failures are logged but don't fail the link — Transactions is the
    // product we actually need; Identity is a bonus for display.
    try {
      await fetchAndStoreIdentity(access_token, itemId);
    } catch (error) {
      console.warn(
        '[identity] Auto-fetch on link failed:',
        error.response?.data || error.message
      );
    }

    res.json({
      item_id: itemId,
      institution: institution?.name || 'Unknown',
      accounts: savedAccounts,
    });
  } catch (error) {
    console.error('Error exchanging token:', error.response?.data || error.message);
    res.status(500).json({ error: 'Failed to exchange token' });
  }
});

/**
 * Call /identity/get and persist the owner info onto plaid_accounts.
 * Plaid returns an array of accounts, each with an `owners` array
 * including full mailing addresses, all emails, and all phones. We
 * store:
 *   - Flat columns (owner_name, owner_email, owner_phone) for quick
 *     UI display. These are the primary values.
 *   - owners_json as an AES-256-GCM encrypted blob since it contains
 *     full addresses and all secondary identity values — the highest
 *     PII concentration anywhere in the DB.
 */
async function fetchAndStoreIdentity(accessToken, localItemId) {
  const response = await plaidClient.identityGet({ access_token: accessToken });

  const updateStmt = db.prepare(`
    UPDATE plaid_accounts SET
      owner_name = ?,
      owner_email = ?,
      owner_phone = ?,
      owners_json = ?,
      identity_fetched_at = datetime('now')
    WHERE plaid_account_id = ?
  `);

  for (const acct of response.data.accounts) {
    const owners = acct.owners || [];
    const primary = owners[0] || {};
    const primaryName = primary.names?.[0] || null;
    const primaryEmail =
      primary.emails?.find((e) => e.primary)?.data ||
      primary.emails?.[0]?.data ||
      null;
    const primaryPhone =
      primary.phone_numbers?.find((p) => p.primary)?.data ||
      primary.phone_numbers?.[0]?.data ||
      null;

    updateStmt.run(
      primaryName,
      primaryEmail,
      primaryPhone,
      encrypt(JSON.stringify(owners)),
      acct.account_id
    );
  }

  console.log(
    `[identity] Stored identity for ${response.data.accounts.length} accounts on item ${localItemId}`
  );
}

// POST /api/transactions/sync — Sync transactions for all linked items
router.post('/transactions/sync', async (req, res) => {
  try {
    const items = db.prepare('SELECT * FROM plaid_items').all();
    if (items.length === 0) {
      return res.json({ added: [], modified: [], removed: [] });
    }

    const allAdded = [];
    const allModified = [];
    const allRemoved = [];

    for (const item of items) {
      const result = await syncTransactionsForItem(item);
      allAdded.push(...result.added);
      allModified.push(...result.modified);
      allRemoved.push(...result.removed);
    }

    // Clear the webhook-set "new data pending" flag now that the app
    // has the latest state. Keep initial/historical completion flags.
    db.prepare(`
      UPDATE sync_cursors SET pending_update_available = 0
    `).run();

    res.json({
      added: allAdded,
      modified: allModified,
      removed: allRemoved,
    });
  } catch (error) {
    console.error('Error syncing transactions:', error.response?.data || error.message);
    res.status(500).json({ error: 'Failed to sync transactions' });
  }
});

// GET /api/transactions/status — Sync lifecycle state per item.
// The app hits this on launch to decide whether to show "still
// backfilling..." messaging or automatically trigger a sync because
// new data is waiting.
router.get('/transactions/status', (_req, res) => {
  const rows = db.prepare(`
    SELECT i.id, i.item_id, i.institution_name,
           COALESCE(sc.initial_update_complete, 0) AS initial_update_complete,
           COALESCE(sc.historical_update_complete, 0) AS historical_update_complete,
           COALESCE(sc.pending_update_available, 0) AS pending_update_available,
           sc.last_synced_at
    FROM plaid_items i
    LEFT JOIN sync_cursors sc ON sc.plaid_item_id = i.id
  `).all();

  res.json({
    items: rows.map((r) => ({
      id: r.id,
      item_id: r.item_id,
      institution_name: r.institution_name,
      initial_update_complete: !!r.initial_update_complete,
      historical_update_complete: !!r.historical_update_complete,
      pending_update_available: !!r.pending_update_available,
      last_synced_at: r.last_synced_at,
    })),
  });
});

// GET /api/balances/history — Balance snapshots over time per account.
//
// Query params:
//   ?days=N (optional) — how far back to look. Default 365.
//
// Returns a flat list of { plaid_account_id, balance_current,
// balance_available, balance_limit, balance_iso_currency_code,
// fetched_at } ordered by fetched_at ASC. The client groups by
// account for charting.
//
// History rows are NOT cascade-deleted when an item is removed, so
// this endpoint still returns data for accounts the user has since
// disconnected — useful as an offline archive of historical net worth.
router.get('/balances/history', (req, res) => {
  const days = Math.min(3650, Math.max(1, Number(req.query.days) || 365));
  const rows = db.prepare(`
    SELECT plaid_account_id, balance_current, balance_available,
           balance_limit, balance_iso_currency_code, fetched_at
    FROM plaid_balance_history
    WHERE fetched_at >= datetime('now', ?)
    ORDER BY fetched_at ASC
  `).all(`-${days} days`);
  res.json({ snapshots: rows });
});

// GET /api/accounts — List all linked accounts (with cached balances).
//
// Explicitly enumerates columns rather than SELECT * so we do not leak
// owners_json (the encrypted blob with full addresses) to the app.
// The flat owner_name / owner_email / owner_phone fields are enough
// for display; owners_json stays server-side.
router.get('/accounts', (_req, res) => {
  const accounts = db.prepare(`
    SELECT
      a.id, a.plaid_item_id, a.plaid_account_id,
      a.name, a.official_name, a.type, a.subtype, a.mask,
      a.balance_current, a.balance_available, a.balance_limit,
      a.balance_iso_currency_code, a.balance_fetched_at,
      a.owner_name, a.owner_email, a.owner_phone, a.identity_fetched_at,
      i.institution_name, i.institution_id,
      i.item_id as plaid_item_id_ref,
      sc.last_synced_at
    FROM plaid_accounts a
    JOIN plaid_items i ON a.plaid_item_id = i.id
    LEFT JOIN sync_cursors sc ON sc.plaid_item_id = i.id
    ORDER BY i.institution_name, a.name
  `).all();
  res.json({ accounts });
});

// POST /api/balances/refresh — Fetch live balances from Plaid for all items.
//
// Hits /accounts/balance/get which forces a real-time pull from the bank
// (as opposed to /accounts/get which can return cached data). Latency is
// higher (p50 ~3s) and each call is billed, so this is gated behind an
// explicit user action — we never refresh on app launch or automatically.
//
// Body (optional):
//   { item_id: <local item UUID> }  — refresh a single item only.
//   { min_age_seconds: 300 }        — skip items fetched more recently.
router.post('/balances/refresh', async (req, res) => {
  const { item_id, min_age_seconds } = req.body || {};

  const items = item_id
    ? db.prepare('SELECT * FROM plaid_items WHERE id = ?').all(item_id)
    : db.prepare('SELECT * FROM plaid_items').all();

  if (items.length === 0) {
    return res.json({ refreshed: [], skipped: [], errors: [] });
  }

  const refreshed = [];
  const skipped = [];
  const errors = [];

  const updateAccount = db.prepare(`
    UPDATE plaid_accounts SET
      balance_current = ?,
      balance_available = ?,
      balance_limit = ?,
      balance_iso_currency_code = ?,
      balance_last_updated_plaid = ?,
      balance_fetched_at = datetime('now')
    WHERE plaid_account_id = ?
  `);

  const insertHistory = db.prepare(`
    INSERT INTO plaid_balance_history
      (plaid_account_id, balance_current, balance_available,
       balance_limit, balance_iso_currency_code)
    VALUES (?, ?, ?, ?, ?)
  `);

  for (const item of items) {
    // Optional freshness gate — skip if we refreshed recently.
    if (min_age_seconds && Number.isFinite(min_age_seconds)) {
      const stale = db.prepare(`
        SELECT MIN(balance_fetched_at) AS oldest
        FROM plaid_accounts
        WHERE plaid_item_id = ?
      `).get(item.id);
      if (stale?.oldest) {
        const ageMs = Date.now() - new Date(stale.oldest + 'Z').getTime();
        if (ageMs < min_age_seconds * 1000) {
          skipped.push({ item_id: item.id, reason: 'fresh' });
          continue;
        }
      }
    }

    try {
      const response = await plaidClient.accountsBalanceGet({
        access_token: tokenOf(item),
      });

      const updatedAccounts = [];
      for (const acct of response.data.accounts) {
        const bal = acct.balances || {};
        updateAccount.run(
          bal.current ?? null,
          bal.available ?? null,
          bal.limit ?? null,
          bal.iso_currency_code ?? bal.unofficial_currency_code ?? null,
          bal.last_updated_datetime ?? null,
          acct.account_id
        );
        // Snapshot into balance history so we can chart trends and
        // retain the data even if Plaid is later disconnected.
        insertHistory.run(
          acct.account_id,
          bal.current ?? null,
          bal.available ?? null,
          bal.limit ?? null,
          bal.iso_currency_code ?? bal.unofficial_currency_code ?? null
        );
        updatedAccounts.push({
          plaid_account_id: acct.account_id,
          name: acct.name,
          type: acct.type,
          subtype: acct.subtype,
          mask: acct.mask,
          balance_current: bal.current ?? null,
          balance_available: bal.available ?? null,
          balance_limit: bal.limit ?? null,
          balance_iso_currency_code: bal.iso_currency_code ?? null,
        });
      }

      refreshed.push({
        item_id: item.id,
        institution_name: item.institution_name,
        accounts: updatedAccounts,
      });
    } catch (error) {
      errors.push({
        item_id: item.id,
        institution_name: item.institution_name,
        error: logAndSanitize(`balances/${item.id}`, error, 'Failed to refresh balance'),
      });
    }
  }

  res.json({ refreshed, skipped, errors });
});

// DELETE /api/items/:id — Disconnect a linked institution.
//
// Calls Plaid /item/remove to invalidate the access_token server-side
// (stops billing, revokes consent), then deletes every row we hold
// for the item. Cascade drops plaid_accounts and sync_cursors; we
// manually clean webhook_events too since it does not cascade.
//
// Per Plaid offboarding guidance: call /item/remove whenever the user
// disconnects the account OR we no longer need the Item. This is the
// authoritative way to stop billing and honor user privacy.
router.delete('/items/:id', async (req, res) => {
  const { id } = req.params;
  const item = db.prepare('SELECT * FROM plaid_items WHERE id = ?').get(id);
  if (!item) {
    return res.status(404).json({ error: 'Item not found' });
  }

  try {
    await plaidClient.itemRemove({ access_token: tokenOf(item) });
  } catch (error) {
    // Log but continue — if the Plaid call fails (access token already
    // invalidated, rate limit, etc.), we still want to drop our local
    // rows. Leaving orphaned rows is worse than a best-effort call.
    console.error('Error removing item from Plaid:', error.response?.data || error.message);
  }

  // Remove from local DB (plaid_accounts + sync_cursors cascade via FK).
  db.prepare('DELETE FROM plaid_items WHERE id = ?').run(id);
  // webhook_events uses Plaid's item_id (not our local uuid) and has
  // no FK, so clean it up explicitly for data hygiene.
  db.prepare('DELETE FROM webhook_events WHERE item_id = ?').run(item.item_id);

  console.log(`[offboarding] Removed item ${item.item_id} (${item.institution_name || 'unknown'})`);
  res.json({ success: true });
});

// DELETE /api/items — Disconnect ALL linked institutions (offboarding).
//
// Used when the user wants to remove Plaid entirely from the app.
// Calls /item/remove for every linked item, then wipes the local
// Plaid tables. Does not touch app-level data (transactions, budgets)
// — the user may want to keep their spending history even after
// unlinking the banks.
//
// Requires ?confirm=DISCONNECT_ALL as a safety rail: a typo-driven
// stray DELETE is otherwise catastrophic (revokes every access token
// and wipes local Plaid state). The Swift app sends this flag
// explicitly after the user confirms the destructive dialog.
router.delete('/items', async (req, res) => {
  if (req.query.confirm !== 'DISCONNECT_ALL') {
    return res.status(400).json({
      error: 'Bulk disconnect requires ?confirm=DISCONNECT_ALL',
    });
  }

  const items = db.prepare('SELECT * FROM plaid_items').all();
  const removed = [];
  const errors = [];

  for (const item of items) {
    try {
      await plaidClient.itemRemove({ access_token: tokenOf(item) });
      removed.push({ item_id: item.id, institution_name: item.institution_name });
    } catch (error) {
      errors.push({
        item_id: item.id,
        institution_name: item.institution_name,
        error: logAndSanitize(`offboarding/${item.id}`, error, 'Failed to disconnect'),
      });
      // Continue — we still remove locally to honor the user's intent.
    }
  }

  db.prepare('DELETE FROM plaid_items').run();
  db.prepare('DELETE FROM webhook_events').run();
  // plaid_accounts and sync_cursors cascade from plaid_items.

  console.log(`[offboarding] Bulk remove: ${removed.length} items, ${errors.length} errors`);
  res.json({ removed, errors });
});

/**
 * Sync transactions for one item via /transactions/sync.
 *
 * Handles two subtleties from the Plaid docs:
 *
 * 1. Pagination mutation: if Plaid has new data DURING our pagination
 *    walk, the API returns TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION.
 *    We catch that, restart from the cursor we started this call with,
 *    and try again (up to 3 times to avoid infinite loops).
 *
 * 2. The cursor we persist is the one from the LAST page. We must not
 *    persist intermediate cursors — if we crash mid-pagination, we
 *    should resume from the same starting cursor, not a half-consumed
 *    middle cursor.
 */
async function syncTransactionsForItem(item, maxAttempts = 3) {
  const cursorRow = db
    .prepare('SELECT cursor FROM sync_cursors WHERE plaid_item_id = ?')
    .get(item.id);
  const startingCursor = cursorRow?.cursor || undefined;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const added = [];
    const modified = [];
    const removed = [];

    let cursor = startingCursor;
    let hasMore = true;
    let finalCursor = startingCursor;

    try {
      while (hasMore) {
        const response = await plaidClient.transactionsSync({
          access_token: tokenOf(item),
          cursor,
          count: 500,
        });
        const data = response.data;

        for (const txn of data.added) added.push(mapTransaction(txn, item));
        for (const txn of data.modified) modified.push(mapTransaction(txn, item));
        for (const id of data.removed) {
          removed.push({ transaction_id: id.transaction_id, item_id: item.id });
        }

        cursor = data.next_cursor;
        finalCursor = cursor;
        hasMore = data.has_more;
      }

      // Pagination finished cleanly — persist the final cursor.
      db.prepare(`
        UPDATE sync_cursors SET cursor = ?, last_synced_at = datetime('now')
        WHERE plaid_item_id = ?
      `).run(finalCursor, item.id);

      return { added, modified, removed };
    } catch (error) {
      const code = error.response?.data?.error_code;
      if (code === 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' && attempt < maxAttempts) {
        console.warn(
          `[transactions] Mutation during pagination for item ${item.id}; retry ${attempt}/${maxAttempts - 1}`
        );
        continue; // restart from startingCursor
      }
      // ITEM_LOGIN_REQUIRED usually surfaces here before the webhook
      // arrives. Flag the item so the app can prompt update mode.
      if (code === 'ITEM_LOGIN_REQUIRED') {
        markNeedsUpdate(item.id, 'ITEM_LOGIN_REQUIRED');
      }
      throw error;
    }
  }

  // Shouldn't reach here (loop returns or throws), but satisfy the linter
  return { added: [], modified: [], removed: [] };
}

// Map a Plaid transaction to our clean format
function mapTransaction(txn, item) {
  return {
    transaction_id: txn.transaction_id,
    account_id: txn.account_id,
    item_id: item.id,
    institution_name: item.institution_name,
    name: txn.name,
    merchant_name: txn.merchant_name || null,
    amount: txn.amount, // Positive = expense, negative = income (Plaid convention)
    date: txn.date,
    pending: txn.pending,
    category: txn.personal_finance_category?.primary || null,
    category_detailed: txn.personal_finance_category?.detailed || null,
  };
}

export default router;
