# Security Model

How BudgetTracking stores and protects the data it pulls from Plaid.

## Threat model

The threats this design defends against, in priority order:

1. **Access-token theft** — someone copies `plaid.db` off the box and uses the stored token to pull bank data directly from Plaid. Mitigated by AES-256-GCM encryption of the token with a key stored outside the database.
2. **PII exposure** — someone reads the raw database file and obtains full mailing addresses / identity info from the Identity product response. Mitigated by encrypting `owners_json` at rest.
3. **Unauthorized API access** — someone discovers the public ngrok URL and calls `/api/*` endpoints directly. Mitigated by `X-App-Token` shared-secret auth.
4. **Spoofed webhooks** — someone forges a Plaid webhook to confuse the sync state. Mitigated by ES256 JWT signature verification against Plaid's public key.

Out of scope: physical access to the user's unlocked Mac; compromise of the user's iCloud account; Plaid's own systems.

## Where data lives

### Server (`server/plaid.db` — SQLite on the user's Mac)

| Column | Content | Protection |
|--------|---------|------------|
| `plaid_items.access_token` | Plaid access token | **AES-256-GCM** |
| `plaid_items.item_id` | Plaid's item identifier | File ACL 0600 |
| `plaid_items.institution_*` | Bank name + ID | File ACL 0600 |
| `plaid_accounts.balance_*` | Current/available/limit/currency | File ACL 0600 |
| `plaid_accounts.owner_name/email/phone` | Primary identity, flat columns | File ACL 0600 |
| `plaid_accounts.owners_json` | Full identity (addresses etc.) | **AES-256-GCM** |
| `sync_cursors.cursor` | Opaque Plaid pagination cursor | File ACL 0600 |
| `webhook_events.payload` | Webhook JSON metadata | File ACL 0600, 30-day retention |

The encryption key is 32 random bytes, loaded in this order:
1. `ENCRYPTION_KEY` env var (32-byte hex, or any passphrase stretched with scrypt)
2. `.encryption-key` file (auto-generated on first boot, chmod 0600)

Losing the key makes encrypted values unrecoverable. Users would need to call `/item/remove` for every bank and re-link.

### Server — HTTP endpoints

| Endpoint | Auth | Notes |
|----------|------|-------|
| `/api/*` | `X-App-Token` header | Constant-time comparison; 401 on mismatch |
| `/webhook` | Plaid JWT signature | ES256 + 5-minute max-age + SHA-256 body hash |
| `/health` | None | Returns only environment + status string |

### macOS app (`~/Library/Application Support/BudgetTracking/budget.sqlite`)

Transactions, categories, budgets, and cached Plaid account metadata live in a GRDB-managed SQLite file. Protection is **macOS FileVault** (disk-level encryption). The app does not add a second encryption layer on top.

Bank credentials are **never** seen by the app — they go directly from the user's browser to Plaid.

### iCloud (optional)

If the user enables sync, the app replicates records via CloudKit into their private iCloud container. CloudKit encrypts records in transit and at rest in Apple's infrastructure; only devices signed into the user's Apple ID can decrypt.

## Key practices

- **No plaintext secrets in logs.** Server logs only print institution names, local UUIDs, and webhook codes — never access tokens or full owner data.
- **Explicit user action for billing calls.** Balance refresh and Identity refresh are only called when the user clicks a button (no background polling).
- **Opt-in consent.** The app shows a pre-Link consent screen on first link covering what data is collected, where it is stored, and which third parties are involved.
- **Hard delete on disconnect.** `/api/items/:id` calls Plaid's `/item/remove` (invalidating the token server-side) and deletes local rows for the item + its webhook events.
- **Full offboarding.** `/api/items` (DELETE) revokes every bank at once. App transaction history stays — users can keep their spending data even after unlinking.
- **Webhook log retention.** Webhook payloads older than 30 days are pruned automatically.

## Reporting

Found a vulnerability? Open a private security advisory at <https://github.com/ajschleg/BudgetTracking/security/advisories/new>.
