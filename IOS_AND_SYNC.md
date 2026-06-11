# iOS App and Sync Architecture

Where data comes from, where it lives, how it moves between devices.
(Rewritten 2026-06-11 for the server-hub architecture; the previous
version documented the CloudKit + LAN design that Phase 3 removed.)

## The one-sentence model

The Mac mini's Node server owns ALL data; every device — macOS or iOS —
is a cache that pulls deltas by cursor and pushes edits over the same
authenticated HTTPS API.

## End-to-end data flow

```
 Plaid API ──▶ Node server on the Mac mini (tailnet HTTPS)
               ├─ transactions table        (source of truth)
               ├─ server_records table      (categories/rules/snapshots/
               │                             profiles/file-metadata as
               │                             opaque JSON payloads)
               ├─ plaid_items/accounts      (tokens AES-256-GCM at rest)
               └─ auto-ingest timer         (Plaid → store, every 6h)
                      ▲│
              push ───┘└─── pull (change_seq cursors)
                      ││
        ┌─────────────┴┴─────────────┐
        │ macOS app                  │ iOS app
        │ ServerTransactionSync      │ same two services, same code
        │ ServerRecordSync           │ (Sources/BudgetTracking is shared)
        │ GRDB budget.sqlite = cache │ GRDB cache on device
        └────────────────────────────┘
```

## Sync mechanics (both feeds)

- **Pull**: `GET /api/{transactions,records}/changes?since=<seq>` paged by
  500; the cursor persists per page, so interrupted pulls resume exactly.
- **Push**: rows whose `lastModifiedAt` passed the watermark, minus rows
  whose stamp round-tripped from a pull. Inserts are idempotent; byte-
  identical record payloads and no-op patches are seq-silent server-side —
  the two layers that make cross-device echo loops structurally impossible.
- **Merge**: last-write-wins by server `updated_at`; manually-categorized
  transactions never lose to robot updates; content-key collisions
  (e.g. same category name created on two devices) resolve to the
  lexicographically smaller UUID on every device, loser remapped +
  tombstoned.
- **Recovery**: Settings → Bank Connection → "Re-sync from server"
  rewinds cursors/watermarks/stamps and re-walks everything. Used after
  restoring a server backup.

## iOS specifics

- Settings tab holds the Server URL + App Auth Token (same values as the
  Mac). A green Test Connection enables sync and triggers the first pull.
- Bank linking runs LinkKit against a `link_token` from `/api/link/create`
  and exchanges via `/api/link/exchange` — directly on the server. The Mac
  app does not need to be running.
- "Reset local data" wipes the device cache, rewinds both cursors, and
  re-pulls. The server is untouched.
- OAuth-bank redirects still use the GitHub Pages bounce; universal-link
  handling on iOS remains a follow-up (see IOS_TODO.md).
