# iOS App and Sync Architecture

Where data comes from, where it lives, how it moves between devices.
The macOS app has been the primary UI from day one. The iOS app is a
viewer + remote-control of the same data, added in the `ios-app`
branch series.

## End-to-end data flow

```
                  ┌─────────────────────────────────────────────────┐
                  │   macOS app (the user's laptop)                 │
                  │                                                 │
  Plaid API       │   ┌──────────────────────────┐                  │
  (live banks) ───┼──▶│ Plaid /server/           │                  │
                  │   │ Node.js, localhost:3000  │                  │
                  │   │ Holds access_tokens      │                  │
                  │   │ AES-256-GCM at rest      │                  │
                  │   │ See server/routes/       │                  │
                  │   │ plaid.js, webhooks.js    │                  │
                  │   └──────────┬───────────────┘                  │
                  │              ▼                                  │
  CSV / OFX /     │   ┌──────────────────────────┐                  │
  QIF / PDF /     │──▶│ Statement parsers        │                  │
  XLSX statement  │   │ (Sources/.../Parsing/)   │                  │
  files via       │   └──────────┬───────────────┘                  │
  Imports tab     │              ▼                                  │
                  │   ┌──────────────────────────┐                  │
                  │   │ Categorization engine    │                  │
                  │   │ + user-defined rules     │                  │
                  │   └──────────┬───────────────┘                  │
                  │              ▼                                  │
  Manual edits    │   ┌──────────────────────────┐                  │
  (Transactions / │──▶│ DatabaseManager (GRDB)   │◀── source of     │
  Categories      │   │ ~/Library/Application    │    truth, on     │
  pages)          │   │ Support/BudgetTracking/  │    disk          │
                  │   │ budget.sqlite            │                  │
                  │   └──────────┬───────────────┘                  │
                  │              │                                  │
                  │   ┌──────────┴───────────────┐                  │
                  │   ▼                          ▼                  │
                  │ ┌─────────────┐      ┌──────────────┐           │
                  │ │ SyncEngine  │      │ LANSyncEngine│           │
                  │ │(CKSyncEngine│      │  (Bonjour    │           │
                  │ │             │      │   _budgetsync│           │
                  │ │             │      │   ._tcp)     │           │
                  │ └──────┬──────┘      └──────┬───────┘           │
                  └────────┼────────────────────┼──────────────────-┘
                           │                    │
                           ▼                    │
                  ┌──────────────────┐          │
                  │ iCloud private   │          │
                  │ database         │          │
                  │ iCloud.com.      │          │
                  │ schlegel.        │          │
                  │ BudgetTracking   │          │
                  └────────┬─────────┘          │
                           │                    │
                           ▼                    ▼
                  ┌────────────────────────────────────────┐
                  │ iOS app (same Apple ID + same Wi-Fi)   │
                  │                                        │
                  │ SyncEngine + LANSyncEngine             │
                  │   ↓                                    │
                  │ DatabaseManager (GRDB, sandboxed)      │
                  │   ↓                                    │
                  │ Dashboard / Transactions / Budget /    │
                  │ Settings tabs                          │
                  └────────────────────────────────────────┘
```

The mental model: **the Mac is the data hub. iOS is a viewer that reads
via two independent transports (iCloud and LAN) and never originates
Plaid data on its own** — Plaid requires a long-lived `access_token`
that lives only on the Mac's `/server/`.

## Data sources

| Source | Where it runs | Output |
| --- | --- | --- |
| Plaid API | `/server/` on the Mac (localhost:3000) | live bank transactions, refreshed on schedule and via Plaid webhooks |
| Statement imports | macOS Imports tab | CSV / OFX / QIF / PDF / XLSX rows, parsed into the same `Transaction` schema |
| Manual edits | Either app's Transactions, Budget, Categories pages | recategorizations, budget changes, new categories, etc. |

All three flow into the same `transaction` / `budgetCategory` / etc.
tables in the macOS GRDB database. From there, two sync engines fan
the data out.

## The two sync transports

The same records sync over **both** transports independently. They're
not redundant — each fixes the other's blind spots:

| Transport | Topology | Best for | Limitation |
| --- | --- | --- | --- |
| `SyncEngine` (CloudKit) | iCloud private database, container `iCloud.com.schlegel.BudgetTracking` | works anywhere with internet, persists across restarts, async push delivery | requires same Apple ID on both devices, slow / flaky in the iOS Simulator |
| `LANSyncEngine` (Bonjour) | direct Mac↔iOS over local Wi-Fi, service `_budgetsync._tcp` | fast, works without iCloud, real-time when both apps are foreground | only when both devices are on the same Wi-Fi |

Both engines write into the same shared GRDB schema, so the iOS UI
reads "whoever wrote the row last" without caring which transport
delivered it.

### CloudKit (`SyncEngine`)

Single private database, single custom zone (`BudgetZone`), uses Apple's
high-level `CKSyncEngine` (iOS 17+ / macOS 14+) which handles change
tokens, push subscriptions, and conflict batches. The iOS app
registers for remote notifications via `UIApplicationDelegateAdaptor`
so push delivery wakes the engine in the background.

### LAN (`LANSyncEngine`)

Bonjour discovery + a small length-prefixed JSON wire protocol over
TCP. Each peer both `NWListener`s and `NWBrowser`s, so when two
devices come online they each open an outbound connection to the
other — producing **two TCP sockets per pair**. `handleHandshake`
deterministically tiebreaks: the connection initiated by the peer
with the lexically larger `deviceId` survives, the other is
cancelled. Both sides compute the same survivor.

The wire format:

```
┌────────────────┬─────────────────────────────────┐
│ 4 bytes BE len │ JSON-encoded SyncMessage payload │
└────────────────┴─────────────────────────────────┘
```

`SyncWireProtocol.decode(from:)` rejects length prefixes above 100 MB
to recover from buffer corruption (otherwise a corrupted prefix would
make decode wait for billions of bytes that never arrive — real
symptom we hit on the Mac during the dual-connection race).

### Foreign-key behavior during sync

The local schema has FK constraints (`transaction.importedFileId →
importedFile.id`, `categorizationRule.categoryId → budgetCategory.id`,
etc.). During the LAN sync apply path, FK enforcement is **disabled**
via `PRAGMA foreign_keys = OFF`. This is deliberate: the user can
hard-delete `ImportedFile` rows on the Mac long after the underlying
transactions were imported, leaving dangling references in the source
of truth. Without the FK disable, ~13% of transactions failed to
apply on the iPhone after a fresh resync.

The dashboard / transactions / budget queries don't `JOIN` on
`importedFile`, so dangling FKs are invisible to the UI.

## CloudKit container layout

| Item | Value |
| --- | --- |
| Container identifier | `iCloud.com.schlegel.BudgetTracking` |
| Database | private |
| Zone | `BudgetZone` (custom) |
| macOS bundle id | `com.schlegel.BudgetTracking` |
| iOS bundle id | `com.schlegel.BudgetTracking.iOS` |
| Shared between bundles | yes — both apps target the same container |

The two bundle ids are intentionally distinct so both apps can install
side-by-side on the same Mac (via Designed for iPad). They share the
container so records sync across them.

## iOS app structure

`Sources/BudgetTrackingIOS/` — iOS-only views and entry point.
Compiles into the `BudgetTracking-iOS` target alongside the shared
`Sources/BudgetTracking/` (models, database, parsing, sync, services,
view models). The macOS shell (`BudgetTrackingApp.swift`,
`ContentView.swift`, `Views/**`) is excluded from iOS via
`project.yml`; iOS has its own `App.swift`, `ContentView.swift`,
and per-tab views.

| Tab | Backed by | What it does |
| --- | --- | --- |
| Dashboard | `DashboardViewModel` | Month picker, overall budget bar, per-category bars, income card, sync-status indicators (iCloud + LAN) |
| Transactions | `TransactionsViewModel` | Searchable, date-grouped list. Tap a row → category picker sheet. Reuses `RuleLearner` so changes retrain rules. |
| Budget | `CategoriesViewModel` | List of categories with monthly budgets. Editor sheet with name, budget, color palette, hidden / income flags. |
| Settings | local | iCloud + LAN status, "Sync now", "Enable LAN sync" toggle, **Reset Local Data** action, version |

All four tabs auto-refresh on `.localDataDidChange` so a CloudKit pull
or LAN sync immediately re-renders the visible tab.

### iOS-specific quirks

- **No default seeding on iOS.** `DatabaseManager.init` no longer
  auto-seeds the canonical category list; that runs only when the
  macOS app calls `seedDefaultsIfNeeded()`. iOS starts with an empty
  DB and pulls everything from the Mac via sync. Seeding on iOS would
  produce duplicate categories with mismatched UUIDs after the first
  sync.
- **Reset Local Data.** Settings → Maintenance section has a
  destructive button that wipes every user-data table on the iPhone
  and resets the LAN sync timestamp, then triggers an immediate
  re-sync. Use it whenever iOS data drifts (e.g., during development
  iteration).
- **LAN sync defaults ON.** The iOS app sets `LANSync_isEnabled = true`
  on first launch (one-time, gated by a `iOS_LANSyncDefaultApplied`
  flag). The macOS app stays opt-in.
- **Local Network permission prompt.** iOS prompts the first time
  Bonjour fires. Required keys (`NSBonjourServices`,
  `NSLocalNetworkUsageDescription`, `UIBackgroundModes` =
  `remote-notification`) live in `Sources/BudgetTrackingIOS/Info.plist`
  via `project.yml`'s `info.properties` section so they're encoded
  as proper plist arrays rather than `INFOPLIST_KEY_*` strings.

## Testing

| Path | Tool | Reliability |
| --- | --- | --- |
| Unit tests (DB, sync wire protocol, dedup logic) | `xcodebuild test` on the `BudgetTracking` macOS scheme | high — runs via the pre-commit hook |
| iOS app on the Simulator | Xcode → `BudgetTracking-iOS` scheme → iPhone simulator | medium — UI works, CloudKit unreliable, Bonjour to host can be flaky |
| iOS app on a physical iPhone | Xcode → `BudgetTracking-iOS` scheme → device | high — real iCloud, real Bonjour, real push notifications |

The unit tests cover the bug surfaces we hit hardest during the
port: wire protocol round-trip, fragmented receive buffers, the
implausible-length corruption guard, transaction dedup behavior, and
the lastModifiedAt conflict-resolution rule. See
`Tests/BudgetTrackingTests/SyncWireProtocolTests.swift` and
`LANSyncDedupTests.swift`.

## Known not-yet-built

- **Plaid Link iOS SDK + LAN backend client.** The iPhone can't
  trigger a Plaid refresh on its own. Originally roadmap PR 8.
  Approach: the iOS app discovers the Mac's `/server/` over Bonjour,
  forwards `link_token` / `public_token` / `transactions/sync`
  requests through that server. Same `requireAppToken` auth as today.
- **Persistent FK orphan queue.** With FK enforcement disabled during
  sync apply this is no longer load-bearing, but if we ever turn FK
  back on, the in-memory orphan queue should be persisted to a table
  so it survives app restarts.
- **Hosted Plaid backend (deferred).** The user picked LAN-only at
  the start of the port. If the iPhone ever needs to refresh Plaid
  data while away from home Wi-Fi, the `/server/` would need to be
  hostable somewhere (Railway / Fly.io / Vapor on a VPS). The
  `PlaidBackend` protocol shape sketched in the original plan keeps
  this swap simple when we get there.

## Where to start reading

If you're picking up this codebase fresh and want to understand the
sync layer in particular, the recommended reading order:

1. `Sources/BudgetTracking/Database/DatabaseManager.swift` — schema
   and the `upsertFromPeer` / `applyPeerRecord` family that decides
   how an incoming sync record is merged with what's already on disk.
2. `Sources/BudgetTracking/Sync/LANSyncProtocol.swift` — the wire
   format (length-prefixed JSON, message types, `SyncRecord`).
3. `Sources/BudgetTracking/Sync/LANSyncEngine.swift` — Bonjour
   discovery, dual-connection tiebreak, send/receive loops, FK
   disable during apply.
4. `Sources/BudgetTracking/Sync/SyncEngine.swift` — CloudKit path,
   `CKSyncEngine` integration, dependency-ordered apply, orphan
   retry queue.
5. `Sources/BudgetTrackingIOS/BudgetTrackingIOSApp.swift` and
   `Sources/BudgetTrackingIOS/Views/**` — iOS UI built atop the
   shared view models.
