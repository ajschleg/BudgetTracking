# CLAUDE.md

Conventions for future Claude/AI sessions on this repo.

## Read first, write second

Before changing anything that touches Plaid data, auth, storage, or the webhook path, READ these files. They encode non-negotiable decisions:

- **`SECURITY_POLICY.md`** — MUST-follow rules for secrets, auth, validation, logging, and destructive operations. Every new feature is checked against this.
- **`SECURITY.md`** — the current data model (what is stored where, how it is protected).

Any code change that conflicts with `SECURITY_POLICY.md` needs to either update the policy (with justification) or be rewritten.

## Architecture shape

- **macOS app** (SwiftUI + GRDB) is the primary UI. Built via `xcodegen generate && xcodebuild …`. The local GRDB file is a cache of the server store; there is no CloudKit or LAN sync.
- **Node.js server** in `/server/` proxies Plaid API calls so Plaid credentials never ship in the client. Keeps access tokens + PII server-side with AES-256-GCM at rest. Since 2026-06 it is also the **source of truth for transactions**: it ingests the Plaid stream into its own `transactions` table (auto-ingest timer; tailnet-only, so webhooks can't drive it) and devices pull `/api/transactions/changes` by `change_seq` cursor and push edits via `POST/PATCH /api/transactions*` — the app's GRDB copy is a local cache. Since Phase 3 (2026-06) budgets/categories/rules/snapshots/profiles/file-metadata also live on the server (`server_records`, opaque JSON payloads, `/api/records/*`); CloudKit/LAN are gone. The iOS app is a pure client of the same API.
- **GitHub Pages** in `/docs/` hosts the privacy policy, Apple App Site Association file for universal links, and the OAuth bounce page that redirects banks → `budgettracking://` → the macOS app.

## Build commands

```bash
# Regenerate Xcode project after any project.yml change or new source file
xcodegen generate

# Build the macOS app
xcodebuild -project BudgetTracking.xcodeproj -scheme BudgetTracking -configuration Debug build

# Run the server
cd server && npm start
```

## Running persistently (Mac mini)

In production the server runs as a **LaunchDaemon** (`com.schlegel.budgettracking-server`)
managed by `server/deploy/budgettracking-server.sh` — the single canonical
mechanism (an earlier `scripts/launchd/` variant was removed; see
`SERVER_ACCESS.md` for the full ops guide). It starts at boot before login,
auto-restarts on crash (`KeepAlive`), and runs as the login user — not
root — so `.env` / `.encryption-key` / `plaid.db` keep their `0600`
ownership.

```bash
cd server/deploy
./budgettracking-server.sh install|status|restart|logs|uninstall
```

Notes:
- Requires **Node 22 LTS** (`brew install node@22`). Newer Node majors can
  break the `better-sqlite3` native build. The plist pins the absolute
  path `/opt/homebrew/opt/node@22/bin/node`.
- `WorkingDirectory` must stay the `server/` dir so `dotenv` finds `.env`.
- Editing `server/.env` does **not** hot-reload — `restart` to apply
  (without sudo: `kill <node pid>` and `KeepAlive` respawns it).

## Pre-commit test gate

A versioned hook in `scripts/git-hooks/pre-commit` runs the macOS test
suite before any commit lands. Activate it on a fresh clone with:

```bash
git config core.hooksPath scripts/git-hooks
```

The hook auto-skips when the staged change is docs-only (no `.swift`,
`.yml`, `.pbxproj`, `.entitlements`, `.plist`, or `Sources/` / `Tests/`
files). To bypass the gate intentionally on a Swift-touching commit,
use `git commit --no-verify` — but only when the failure is unrelated
to the change at hand.

## What NOT to do without explicit approval

- Commit `.env`, `.encryption-key`, or `plaid.db` (all gitignored — check before force-add).
- Add a new `/api/*` route without `requireAppToken`.
- Introduce a new `UserDefaults` write of a credential — use `KeychainStore`.
- Log an access token, webhook JWT, or raw Plaid error response to console.
- Use `innerHTML =` with interpolated values in any HTML.
- Skip the encryption boundary when reading or writing `access_token` or `owners_json`.

## Common gotchas

- `PLAID_ENV=production` rejects unsigned webhooks. Use sandbox for local testing that does not involve a real Plaid → server delivery path.
- The app auth token and Claude API key are in the macOS Keychain under `com.schlegel.BudgetTracking.*` account names. Reading from `UserDefaults` for these values is a bug.
- `xcodegen` overwrites entitlement files if you use its `entitlements:` key — use `CODE_SIGN_ENTITLEMENTS` build setting instead.
- Xcode project `.pbxproj` is generated. Source of truth is `project.yml`.

## Commit conventions

- Each compliance step / security fix gets its own commit with a descriptive title and detailed body explaining motivation + what was verified.
- Commits include a `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>` trailer.
- Never bypass hooks (`--no-verify`) — fix the underlying issue.
