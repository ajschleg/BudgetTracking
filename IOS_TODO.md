# iOS TODO

Remaining work for iOS feature parity, post-Phase 3 (2026-06-11).
Everything LAN/CloudKit-related from the previous list is obsolete —
iOS is now a pure client of the mini's API.

- [ ] OAuth banks on iOS: wire `onOpenURL`/universal links in
      BudgetTrackingIOSApp so the budgettracking:// bounce returns into
      LinkKit (mirror the macOS AppURLRoute flow).
- [ ] Update-mode (reconnect) flow on iOS: surface needs_update items
      (`GET /api/items`) and drive `/api/link/create-update`.
- [ ] Unlink UI on iOS (`DELETE /api/items/:id`).
- [ ] Editing parity: category assignment + budget edits exist on macOS
      only; iOS views are read-mostly. Edits made on iOS push through the
      same ServerTransactionSync/ServerRecordSync — only the UI is missing.
- [ ] Device verification pass on real hardware: seed-from-empty pull,
      link a sandbox bank, background/foreground cursor behavior.
