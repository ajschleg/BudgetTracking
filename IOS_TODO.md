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
- [x] Editing: SHIPPED, contrary to an earlier version of this note —
      TransactionsView tap-to-recategorize runs the full pipeline
      (updateCategory → RuleLearner → bulk apply → server push) and
      BudgetView has complete category CRUD. Genuinely still missing,
      none currently requested: rules-management UI, Dashboard drill-in
      recategorization (DashboardViewModel.changeTransactionCategory is
      ready and unused on iOS), optional per-device editing lock.
- [ ] Device verification pass on real hardware: seed-from-empty pull,
      link a sandbox bank, background/foreground cursor behavior.
