# iOS Implementation — Remaining Work

Running todo for the iOS port. Captures what is **not yet built** as of
commit `5e08218` (the LinkKit + LAN-proxied Plaid RPC landing), so a
future session can pick up without re-deriving the gaps.

Read `IOS_AND_SYNC.md` first for the architecture this builds on, and
`SECURITY_POLICY.md` before touching anything on the Plaid path.

## Already shipped (do not redo)

So future-me doesn't re-investigate these as "missing":

- iOS target with 4 tabs — Dashboard, Transactions, Budget, Settings —
  on the shared view models.
- CloudKit (`SyncEngine`) + LAN (`LANSyncEngine`) sync, Mac → iPhone.
- **Bank linking on iOS** via LinkKit, proxied over the LAN sync
  channel: `createLinkToken` + `exchangePublicToken` RPCs
  (`Sources/BudgetTracking/Sync/LANPlaidRPC.swift`,
  `LANPlaidClient.swift`, `Views/Settings/PlaidLinkSheet.swift`). iOS
  never holds the server URL or `X-App-Token` — the Mac is the only
  device that talks to `/server/`.
- **Refresh from Plaid** on iOS — a LAN remote-control message asking
  the Mac to run `/transactions/sync` (`SettingsView.requestPlaidRefresh`
  → `LANSyncEngine.requestPlaidRefresh`).
- Pull-to-refresh (`.refreshable`) on Dashboard / Transactions / Budget
  (reloads the local DB; not a Plaid fetch).

## 1. Plaid feature parity (iOS ↔ macOS) — highest priority

The Mac `/server/` exposes a full Plaid surface; the iOS LAN RPC only
proxies link-create + exchange (+ the refresh remote-control). These Mac
capabilities have **no iOS path** yet:

| Capability | macOS today | Server endpoint | iOS status |
| --- | --- | --- | --- |
| OAuth bank return (Chase, Capital One, …) | `onOpenURL` → `Plaid.continue(from:)` in `BudgetTrackingApp.swift:147` | (redirect bounce) | **Missing** — iOS `BudgetTrackingIOSApp` has no `onOpenURL`; OAuth banks can't complete Link on the phone |
| Update mode / re-auth (`ITEM_LOGIN_REQUIRED`) | `PlaidSyncManager.startUpdateMode`, `PlaidUpdateBanner` | `POST /link/create-update`, `POST /items/:id/clear-update` | **Missing** — no RPC method; a broken item can't be fixed from iOS |
| Unlink / remove a bank | `PlaidService.removeItem`, disconnect-all | `DELETE /items/:id`, `DELETE /items` | **Missing** — no RPC method |
| Linked-accounts management UI | `Views/Accounts/AccountsView.swift` | `GET /items`, `GET /accounts` | **Missing** — iOS can add a bank but not list / manage them |

**Work items:**

1. **OAuth bank return on iOS.** Wire `onOpenURL` in
   `BudgetTrackingIOSApp` to call `Plaid.continue(from:)` so OAuth banks
   resume after the `budgettracking://` bounce (this is the follow-up
   called out in the `PlaidLinkSheet.swift` header comment and the
   `5e08218` commit body). Then migrate the bounce to a proper universal
   link using the existing AASA file in `docs/.well-known/`. Confirm the
   `link_token` the Mac mints carries an iOS-appropriate `redirect_uri`.
2. **Update-mode RPC + banner on iOS.** Add a `createUpdateLinkToken(itemId)`
   case to `PlaidRPCMethod`, present LinkKit in update mode, and surface
   an iOS equivalent of `PlaidUpdateBanner` driven by the items the Mac
   reports as needing re-auth.
3. **Unlink RPC + accounts UI on iOS.** Add a `removeItem(itemId)` RPC
   and an iOS accounts screen (list linked banks, per-item sync status,
   unlink). `PlaidAccount` rows already sync down, so the list is mostly
   a read of local data + one new RPC for the destructive action.

> Per `SECURITY_POLICY.md §10`, any new RPC result must stay PII-free —
> no `owner_name` / `_email` / `_phone` across the LAN boundary, matching
> the existing `LANPlaidRPC.swift` contract.

## 2. iOS UX roadmap items not yet started

From the Phase 4 / Phase 6 roadmap (`memory/roadmap_ios_plaid.md`),
verified absent in `Sources/BudgetTrackingIOS/`:

| Item | Notes |
| --- | --- |
| Swipe actions on transactions | Today: tap row → category picker. Add swipe-to-categorize / delete. |
| Statement import on iOS | macOS has the Imports tab + parsers; iOS has no import entry point. Roadmap wanted a share-sheet importer. |
| Income tab | iOS has no Income/eBay tab (Dashboard shows an income card only). |
| New-transaction push notifications | Push is wired for CloudKit wake (`d60a7a1`); no user-facing "new transactions" notification. |
| WidgetKit budget widget | Not built. |
| Privacy manifest (`PrivacyInfo.xcprivacy`) | Not present; Apple requires it before any App Store / TestFlight distribution. Declare Plaid + network data use. |

## 3. Sync robustness

- **Persistent FK-orphan queue.** Both engines hold the orphan retry
  queue in memory (`SyncEngine.swift:374`, `LANSyncEngine.swift:1021`),
  so it's lost on app restart. Low priority while FK enforcement is
  disabled during apply (see `IOS_AND_SYNC.md`), but load-bearing again
  if FK is ever re-enabled — persist it to a table then.

## 4. Documentation

- **Update `IOS_AND_SYNC.md`.** Its "Known not-yet-built" section still
  lists the Plaid Link iOS SDK + LAN backend client as unbuilt — that
  shipped in `5e08218`. Replace it with a section describing the LAN
  Plaid RPC (`createLinkToken` / `exchangePublicToken`), the
  Refresh-from-Plaid remote-control message, and the OAuth bounce, per
  the note in `memory/project_ios_docs_todo.md`.

## 5. Deferred (by decision)

- **Hosted Plaid backend for off-LAN refresh.** iOS can only link /
  refresh when on home Wi-Fi with the Mac awake. If the phone ever needs
  Plaid while away, `/server/` must be hostable (Railway / Fly.io /
  Vapor on a VPS). The `PlaidBackend` protocol shape is the intended
  swap point. Explicitly deferred — the user chose LAN-only for the port.
