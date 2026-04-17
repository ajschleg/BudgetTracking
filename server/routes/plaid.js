import { Router } from 'express';
import { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } from 'plaid';
import { v4 as uuidv4 } from 'uuid';
import db from '../db.js';

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
    };

    // Include redirect_uri for OAuth bank support
    if (redirect_uri) {
      tokenRequest.redirect_uri = redirect_uri;
    }

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

// GET /api/items — List linked items (for webhook testing, debugging)
router.get('/items', (_req, res) => {
  const items = db.prepare(`
    SELECT id, item_id, institution_id, institution_name, created_at
    FROM plaid_items
    ORDER BY created_at DESC
  `).all();
  res.json({ items });
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
      await fetchAndStoreIdentity(item.access_token, item.id);
      refreshed.push({ item_id: item.id, institution_name: item.institution_name });
    } catch (error) {
      console.error(
        `[identity] Refresh failed for item ${item.id}:`,
        error.response?.data || error.message
      );
      errors.push({
        item_id: item.id,
        institution_name: item.institution_name,
        error: error.response?.data?.error_message || error.message,
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
      access_token: item.access_token,
      webhook,
    });
    res.json({ success: true, webhook });
  } catch (error) {
    console.error(
      'Error updating webhook:',
      error.response?.data || error.message
    );
    res.status(500).json({
      error: error.response?.data?.error_message || error.message,
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

    // Save item to DB
    const itemId = uuidv4();
    db.prepare(`
      INSERT OR REPLACE INTO plaid_items (id, item_id, access_token, institution_id, institution_name)
      VALUES (?, ?, ?, ?, ?)
    `).run(
      itemId,
      item_id,
      access_token,
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
 * Plaid returns an array of accounts, each with an `owners` array. We
 * store the primary (first) owner in flat columns for quick display
 * and the full owners array as JSON for future use.
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
      JSON.stringify(owners),
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
      // Get current cursor
      const cursorRow = db.prepare(
        'SELECT cursor FROM sync_cursors WHERE plaid_item_id = ?'
      ).get(item.id);
      let cursor = cursorRow?.cursor || undefined;
      let hasMore = true;

      while (hasMore) {
        const response = await plaidClient.transactionsSync({
          access_token: item.access_token,
          cursor,
          count: 500,
        });

        const data = response.data;

        // Map transactions to a clean format
        for (const txn of data.added) {
          allAdded.push(mapTransaction(txn, item));
        }
        for (const txn of data.modified) {
          allModified.push(mapTransaction(txn, item));
        }
        for (const id of data.removed) {
          allRemoved.push({ transaction_id: id.transaction_id, item_id: item.id });
        }

        cursor = data.next_cursor;
        hasMore = data.has_more;
      }

      // Update cursor
      db.prepare(`
        UPDATE sync_cursors SET cursor = ?, last_synced_at = datetime('now')
        WHERE plaid_item_id = ?
      `).run(cursor, item.id);
    }

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

// GET /api/accounts — List all linked accounts (with cached balances)
router.get('/accounts', (_req, res) => {
  const accounts = db.prepare(`
    SELECT a.*, i.institution_name, i.institution_id, i.item_id as plaid_item_id_ref,
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
        access_token: item.access_token,
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
      console.error(
        `[balances] Failed for item ${item.id}:`,
        error.response?.data || error.message
      );
      errors.push({
        item_id: item.id,
        institution_name: item.institution_name,
        error: error.response?.data?.error_message || error.message,
      });
    }
  }

  res.json({ refreshed, skipped, errors });
});

// DELETE /api/items/:id — Remove a linked institution
router.delete('/items/:id', async (req, res) => {
  const { id } = req.params;
  const item = db.prepare('SELECT * FROM plaid_items WHERE id = ?').get(id);
  if (!item) {
    return res.status(404).json({ error: 'Item not found' });
  }

  try {
    // Remove from Plaid
    await plaidClient.itemRemove({ access_token: item.access_token });
  } catch (error) {
    // Log but continue — we still want to remove from our DB
    console.error('Error removing item from Plaid:', error.response?.data || error.message);
  }

  // Remove from local DB (cascades to accounts and cursors)
  db.prepare('DELETE FROM plaid_items WHERE id = ?').run(id);
  res.json({ success: true });
});

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
