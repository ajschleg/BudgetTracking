# Security Policy — Development Rules

Rules that future code changes must follow. Treat this as a gate: a change that violates any rule should either bring the rule up to date (with justification) or be rewritten. Complements `SECURITY.md` which documents the existing storage model.

---

## 1. Secrets handling

### On the macOS app
- **Any value that grants access to an external system** (API keys, shared secrets, OAuth tokens, bank credentials) MUST live in the Keychain via `KeychainStore` — never `UserDefaults`, `@AppStorage`, `.plist`, or source code.
- **Non-sensitive preferences** (theme, selected month, last-opened tab) are fine in `UserDefaults`.
- Keychain account names MUST be fully-qualified reverse-DNS (`com.schlegel.BudgetTracking.xxx`) so different apps with the same shared team ID do not collide.
- When adding a new secret, include a one-time UserDefaults → Keychain migration so existing installs don't lose their value.

### On the server
- **Every secret** (Plaid keys, app auth token, encryption key, webhook URL) MUST come from `process.env.*` loaded via `dotenv`. No hardcoded credentials.
- `.env` MUST stay in `.gitignore`. `.env.example` uses placeholder values with comments explaining what to set and how.
- Secrets MUST NEVER appear in log output, error responses, or commit messages.
- If a secret is ever committed, treat it as compromised: rotate immediately, do not rely on `git rm` or history rewrites.

---

## 2. Data at rest

- **Plaid access tokens**: encrypted with AES-256-GCM via `server/lib/crypto.js`. Every new read/write path MUST go through `tokenOf(item)` (for reads) and `encrypt(token)` (for writes). Never write `item.access_token` back without encrypting.
- **PII blobs** (`owners_json` etc.): encrypted the same way. If you add a new high-PII column, wrap it with `encrypt()` and `decrypt()` at the boundary.
- **Encryption key**: MUST NEVER be checked into git. Server ensures this by generating `.encryption-key` with `chmod 0600` and listing it in `.gitignore`.
- **DB files**: `server/plaid.db` and WAL files MUST have mode `0600`. The server re-applies this on every startup as defense-in-depth.
- **macOS app SQLite**: relies on FileVault for at-rest encryption (acceptable for local-only personal use). If the app ever ships to multi-user or cloud-sync-only contexts, add SQLCipher.

---

## 3. Authentication & authorization

- **Every `/api/*` route** MUST be gated by `requireAppToken` middleware. No exceptions. New routes added to the `plaidRoutes` router inherit this automatically; new mount points need explicit middleware.
- **`/webhook/events`, `/webhook/fire`**: MUST be gated by `requireAppToken`. Only the webhook POST itself is public, and it MUST verify the Plaid JWT signature.
- **Unsigned webhooks**: accepted only when `PLAID_ENV === 'sandbox'`. Development and production MUST reject `401 Unverified webhook` when the `Plaid-Verification` header is missing or the signature fails.
- **`/health`** stays public but MUST NEVER return data beyond `{ status, env }`.
- New bearer-token comparisons MUST use the existing constant-time helper to resist timing attacks — never `a === b` on secrets.

---

## 4. Input validation & output encoding

- **DB queries**: MUST use parameterized `db.prepare(...).run(...)` / `.get(...)` / `.all(...)`. No string concatenation or template literals in SQL.
- **Route body validation**: any new POST/DELETE MUST null-check and type-check body fields before passing to the DB or Plaid. Never trust `req.body.foo` is a string.
- **HTML rendering**: in `server/public/*.html`, user-controllable or network-derived values MUST go through `textContent` or explicit DOM node construction. Never `innerHTML =` with interpolated values. Same for any future Swift `WKWebView` pages.
- **Error responses to clients**: route through `logAndSanitize(scope, error)` from `server/lib/errors.js`. Raw Plaid errors, stack traces, and system paths MUST stay server-side. A short allowlist of Plaid error codes may be surfaced directly to the user when they are genuinely actionable (e.g. `ITEM_LOGIN_REQUIRED`).

---

## 5. Destructive operations

- **`DELETE /api/items`** (bulk) MUST require `?confirm=DISCONNECT_ALL`. A typo-driven request that omits the flag is rejected with 400.
- **Per-item delete** MUST first call Plaid `/item/remove` (best-effort) and then delete local rows. Do not skip the Plaid call — that would leave tokens live on Plaid's side after user offboarding.
- **Any new destructive endpoint** (wipe, reset, purge) MUST have a confirmation flag AND a user-facing confirmation dialog on the client.
- **Schema migrations that drop data** MUST be reviewed manually. Never auto-drop columns.

---

## 6. Rate limits & abuse

- **`/api/*`**: limited to 60 req/min/IP.
- **`/webhook`**: limited to 300 req/min/IP.
- New public endpoints MUST register a rate limit. Default to `apiLimiter` for app-facing and `webhookLimiter` for Plaid-facing.
- If a feature legitimately needs more than the limit, bump the limit for that specific route — do not remove it.

---

## 7. WKWebView & URL schemes

- WKWebView configuration MUST NOT enable `allowFileAccessFromFileURLs`, `allowUniversalAccessFromFileURLs`, or similar file-access privileges.
- WKWebView navigation MUST whitelist hosts (`localhost`, `cdn.plaid.com`, any domain under `*.plaid.com`, configured ngrok/GitHub Pages). External URLs MUST open in the system browser via `NSWorkspace.shared.open`.
- The `budgettracking://` URL scheme handler MUST validate the host before acting on the URL (`plaid-oauth`, `plaid-oauth-success`, `ebay`, etc.). Unknown hosts are ignored.

---

## 8. Logging

- Server console logs MUST NEVER include: access tokens, API keys, webhook JWTs, owner PII blobs, full Plaid error responses (use `logAndSanitize` to summarize), or full user input.
- Server logs MAY include: institution names, local item UUIDs, Plaid item_ids, webhook codes, error codes without sensitive payload, latencies, HTTP status codes.
- Swift `print(...)` statements MUST NEVER include transaction descriptions, merchant names, owner info, or API keys. Use the narrowest possible summary (count, type, ID) if logging is unavoidable.

---

## 9. Dependencies

- Adding a new npm package: confirm it is actively maintained, review transitive dep count, and prefer pure-Node over native modules when possible. Run `npm audit` after install.
- Adding a new Swift package: confirm it is actively maintained and has a permissive license.
- Update dependencies quarterly at minimum. `plaid-link-ios-spm` MUST be on a version supported by Plaid (they maintain 2-year windows).

---

## 10. What stays on the local machine

- **Never sent to anyone else** (beyond the intended third party): Plaid access tokens, Plaid PII (owner addresses, emails, phones beyond what the app renders itself), bank credentials (they never even come to us — they go directly to Plaid).
- **Sent only to the user's own iCloud** via CloudKit: transactions, budgets, categories, learned rules.
- **Sent to Plaid** only: access tokens (server→Plaid), public tokens (server→Plaid for exchange).
- **Sent to Anthropic** only if the user enables AI insights: aggregated category totals. Never individual transactions unless the user explicitly runs AI categorization on a batch.

---

## 11. Pre-commit gates

Before committing security-sensitive changes, confirm:

- [ ] No plaintext secrets in any staged file (grep for likely patterns)
- [ ] No new `innerHTML =` with interpolated values
- [ ] No new `UserDefaults` writes of credentials
- [ ] No new unguarded `sandbox*` Plaid endpoint calls
- [ ] No new `/api/*` routes without `requireAppToken`
- [ ] No new `error.response.data` strings returned directly to the client
- [ ] `swift build` + `xcodebuild` succeed
- [ ] `node server.js` starts cleanly and prints expected env

When in doubt, add a test that proves the gate works (like the rate-limit curl loop). Shipping without a test means the gate will eventually break.

---

## Change log

- 2026-04-17: Initial policy alongside server-side encryption, Keychain migration, webhook auth, rate limiting, XSS fixes, and bulk-delete confirmation rail.
