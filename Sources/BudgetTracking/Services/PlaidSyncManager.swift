import Foundation
import SwiftUI

/// Protocol covering the parts of PlaidService that PlaidSyncManager
/// touches. Tests provide a mock conforming to this instead of hitting
/// the real network. Every method raises by default — tests override
/// only what their scenario exercises.
protocol PlaidTransactionSyncing {
    func syncTransactions() async throws -> PlaidService.SyncResponse
    func fetchAccounts() async throws -> [PlaidService.AccountListItem]
    func removeItem(_ itemId: String) async throws
    func removeAllItems() async throws -> PlaidService.BulkRemoveResponse
    func refreshBalances(itemId: String?, minAgeSeconds: Int?) async throws -> PlaidService.BalancesRefreshResponse
    func refreshIdentity(itemId: String?) async throws -> PlaidService.IdentityRefreshResponse
    func fetchTransactionsStatus() async throws -> PlaidService.TransactionsStatusResponse
    func fetchItems() async throws -> PlaidService.ItemsResponse
    func createLinkToken() async throws -> String
}

extension PlaidService: PlaidTransactionSyncing {}

@Observable
final class PlaidSyncManager {
    var isSyncing = false
    var syncProgress: String = ""
    /// Sticky summary of the last successful sync: "5 new · 2 duplicates skipped · 1 updated".
    /// Cleared at the start of the next sync. Nil when no sync has run this session.
    var lastSyncSummary: String?
    var errorMessage: String?
    var linkedAccounts: [PlaidAccount] = []

    /// Set when an OAuth redirect is received; triggers PlaidLinkView in completion mode
    var pendingOAuthRedirectURI: String?

    /// True while we are awaiting a response from /accounts/balance/get
    /// via the server. Separate from isSyncing so the UI can show a
    /// distinct spinner for balance refresh vs transaction sync.
    var isRefreshingBalances = false

    /// True while a manual /identity/refresh call is in flight.
    var isRefreshingIdentity = false

    /// Most recent sync-lifecycle status from the server, keyed by item.
    /// Populated by checkTransactionsStatus(); drives UI hints like
    /// "still backfilling" and "new transactions waiting".
    var itemStatuses: [PlaidService.TransactionsStatusItem] = []

    /// Items that need update-mode re-auth, per the server's
    /// needs_update flag (set by webhook handlers or API errors).
    var itemsNeedingUpdate: [PlaidService.ItemSummary] = []

    /// When non-nil, triggers the OAuth/update sheet in update mode for
    /// this local item UUID.
    var pendingUpdateItemId: String?

    /// When true, the pending update sheet should open Plaid Link with
    /// the account picker enabled (account_selection_enabled=true).
    /// Set automatically when the user reconnects an item whose
    /// needs_update_reason is NEW_ACCOUNTS_AVAILABLE.
    var pendingUpdateAccountSelection = false

    private let plaidService: PlaidTransactionSyncing
    private let database: DatabaseManager
    private let serverSync: ServerTransactionSync

    init(
        plaidService: PlaidTransactionSyncing = PlaidService(),
        database: DatabaseManager = .shared,
        serverSync: ServerTransactionSync = .shared
    ) {
        self.plaidService = plaidService
        self.database = database
        self.serverSync = serverSync
    }

    // MARK: - Account Management

    func loadAccounts() {
        do {
            linkedAccounts = try self.database.fetchPlaidAccounts()
        } catch {
            linkedAccounts = []
        }
    }

    func refreshAccountsFromServer() async {
        do {
            let serverAccounts = try await plaidService.fetchAccounts()

            // Sync server accounts to local DB (includes balances + identity)
            for account in serverAccounts {
                let plaidAccount = PlaidAccount(
                    plaidAccountId: account.plaid_account_id,
                    plaidItemId: account.plaid_item_id,
                    institutionName: account.institution_name,
                    name: account.name,
                    officialName: account.official_name,
                    type: account.type,
                    subtype: account.subtype,
                    mask: account.mask,
                    balanceCurrent: account.balance_current,
                    balanceAvailable: account.balance_available,
                    balanceLimit: account.balance_limit,
                    balanceCurrencyCode: account.balance_iso_currency_code,
                    balanceFetchedAt: parseISODate(account.balance_fetched_at),
                    ownerName: account.owner_name,
                    ownerEmail: account.owner_email,
                    ownerPhone: account.owner_phone,
                    identityFetchedAt: parseISODate(account.identity_fetched_at)
                )
                try self.database.savePlaidAccount(plaidAccount)
            }

            loadAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Parse a `yyyy-MM-dd HH:mm:ss` timestamp (SQLite datetime default)
    /// into a Date. Returns nil for nil/empty/invalid inputs.
    private func parseISODate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)
    }

    func removeAccount(_ account: PlaidAccount) async {
        do {
            try await plaidService.removeItem(account.plaidItemId)
            try self.database.deletePlaidAccounts(forItemId: account.plaidItemId)
            loadAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Disconnect every linked bank. Honors user privacy (revokes
    /// Plaid access tokens server-side) and stops any further billing.
    /// Does NOT delete local transaction history — users can keep
    /// their data. Called from Settings when the user opts out entirely.
    func disconnectAllBanks() async {
        do {
            let response = try await plaidService.removeAllItems()

            // Local cleanup: drop every plaidAccount row (the server
            // already wiped its copy). Transactions stay put.
            for account in linkedAccounts {
                try? self.database.deletePlaidAccounts(forItemId: account.plaidItemId)
            }
            loadAccounts()
            itemsNeedingUpdate = []
            itemStatuses = []

            if !response.errors.isEmpty {
                let first = response.errors.first!
                errorMessage = "Some banks couldn't be cleanly unlinked (\(first.institution_name ?? "unknown")): \(first.error). Local data was still removed."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Balance Refresh

    /// Pull live balances from Plaid for every linked item. Surfaces
    /// latency and cost so the UI can expose it behind an explicit button.
    func refreshBalances() async {
        isRefreshingBalances = true
        errorMessage = nil
        defer { isRefreshingBalances = false }

        do {
            let response = try await plaidService.refreshBalances(itemId: nil, minAgeSeconds: nil)

            // Persist fresh balances to the local DB
            let fetchedAt = Date()
            for item in response.refreshed {
                for acct in item.accounts {
                    try? self.database.updatePlaidAccountBalance(
                        plaidAccountId: acct.plaid_account_id,
                        current: acct.balance_current,
                        available: acct.balance_available,
                        limit: acct.balance_limit,
                        currencyCode: acct.balance_iso_currency_code,
                        fetchedAt: fetchedAt
                    )
                }
            }

            loadAccounts()

            if !response.errors.isEmpty {
                let first = response.errors.first!
                errorMessage = "Couldn't refresh \(first.institution_name ?? "account"): \(first.error)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Transactions Status

    /// Poll the server for per-item sync lifecycle state. Cheap, read-only
    /// call (no Plaid API hits); safe to run on app launch. If the server
    /// reports pending updates for any item, auto-kick a transactions sync.
    func checkTransactionsStatus(autoSyncIfPending: Bool = true) async {
        async let updateCheck: Void = refreshUpdateModeStatus()
        do {
            let response = try await plaidService.fetchTransactionsStatus()
            itemStatuses = response.items

            if autoSyncIfPending,
               response.items.contains(where: { $0.pending_update_available }),
               !isSyncing {
                await syncTransactions()
            } else if serverSync.isEnabled, !isSyncing {
                // Store mode: the mini's auto-ingest timer accumulates
                // transactions while this Mac is closed — pull them (and
                // categorize/push) on launch without requiring a manual sync.
                try? await storeModeSync()
            }
        } catch {
            // Status is a best-effort signal; don't surface an error
            // just because the server is offline. The manual Sync
            // button will still work.
        }
        _ = await updateCheck
    }

    /// True if any linked item is still backfilling historical
    /// transactions. UI can use this to show a "still fetching history…"
    /// hint instead of an empty dashboard.
    var isHistoricalBackfillInProgress: Bool {
        guard !itemStatuses.isEmpty else { return false }
        return itemStatuses.contains { !$0.historical_update_complete }
    }

    /// Refresh the list of items whose needs_update flag is set. Cheap
    /// metadata call, no Plaid API hits. Runs alongside the status
    /// check on app launch.
    func refreshUpdateModeStatus() async {
        do {
            let response = try await plaidService.fetchItems()
            itemsNeedingUpdate = response.items.filter { $0.needs_update }
        } catch {
            // Non-fatal; a stale flag is better than a spurious error.
        }
    }

    /// Trigger update-mode Link for the given item. PlaidLinkView will
    /// present the update.html page, Plaid Link re-auths against the
    /// existing access_token, and the server clears the needs_update
    /// flag on success.
    ///
    /// When the item was flagged with NEW_ACCOUNTS_AVAILABLE, we open
    /// Link with the account picker so the user can opt-in the newly
    /// discovered accounts.
    func startUpdateMode(for itemId: String) {
        let isNewAccounts = itemsNeedingUpdate
            .first(where: { $0.id == itemId })?
            .needs_update_reason == "NEW_ACCOUNTS_AVAILABLE"
        pendingUpdateAccountSelection = isNewAccounts
        pendingUpdateItemId = itemId
    }

    /// Called when update-mode Link finishes (success or exit).
    func finishUpdateMode() {
        pendingUpdateItemId = nil
        pendingUpdateAccountSelection = false
        Task {
            await refreshUpdateModeStatus()
            // Pull the reconciled account list down to the app so newly
            // selected accounts appear immediately.
            await refreshAccountsFromServer()
        }
    }

    // MARK: - Identity Refresh

    /// Manually re-fetch /identity/get for every linked item. Identity
    /// is already fetched opportunistically on link, so this is a
    /// fallback for cases where the user changed their info at the bank
    /// or the initial fetch failed.
    func refreshIdentity() async {
        isRefreshingIdentity = true
        errorMessage = nil
        defer { isRefreshingIdentity = false }

        do {
            let response = try await plaidService.refreshIdentity(itemId: nil)
            // Pull the updated rows (with owner_name, email, phone) back
            // onto the device.
            await refreshAccountsFromServer()

            if !response.errors.isEmpty {
                let first = response.errors.first!
                errorMessage = "Couldn't refresh identity for \(first.institution_name ?? "account"): \(first.error)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Link Flow

    func createLinkToken() async throws -> String {
        try await plaidService.createLinkToken()
    }

    func handleLinkSuccess(itemId: String, institution: String, accounts: [PlaidService.AccountResponse]) {
        // Save accounts to local DB
        for account in accounts {
            let plaidAccount = PlaidAccount(
                plaidAccountId: account.plaid_account_id,
                plaidItemId: itemId,
                institutionName: institution,
                name: account.name,
                officialName: account.official_name,
                type: account.type,
                subtype: account.subtype,
                mask: account.mask
            )
            try? self.database.savePlaidAccount(plaidAccount)
        }
        loadAccounts()

        // The server auto-fetched identity during /link/exchange — pull
        // the enriched rows (with owner_name etc.) back to the device.
        Task { await refreshAccountsFromServer() }
    }

    // MARK: - Transaction Sync

    /// The server ingests from Plaid during the call (its store is the
    /// authority); we then pull the deltas, auto-categorize brand-new rows
    /// using the Plaid hints that ride along, and push the assignments
    /// back. Legacy local-apply died with the CK/LAN engines.
    func syncTransactions() async {
        isSyncing = true
        syncProgress = "Syncing transactions..."
        errorMessage = nil
        lastSyncSummary = nil

        defer {
            isSyncing = false
            syncProgress = ""
        }

        do {
            let response = try await plaidService.syncTransactions()
            try await storeModeSync(ingested: response.ingested)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Store-mode follow-up to a server ingest: pull, categorize, push.
    private func storeModeSync(ingested: PlaidService.IngestedCounts? = nil) async throws {
        syncProgress = "Pulling changes from server..."
        guard let pull = await serverSync.pull() else {
            if let message = serverSync.errorMessage {
                errorMessage = message
            }
            return
        }

        var categorizedCount = 0
        if !pull.needsCategorization.isEmpty {
            syncProgress = "Categorizing \(pull.needsCategorization.count) new transactions..."
            var transactions = pull.needsCategorization.map(\.transaction)
            let rules = try database.fetchRules()
            let categories = try database.fetchCategories()
            let engine = CategorizationEngine(rules: rules, categories: categories)
            engine.categorizeAllWithPlaid(
                transactions: &transactions,
                plaidPrimaryCategories: pull.needsCategorization.map(\.plaidPrimary),
                plaidDetailedCategories: pull.needsCategorization.map(\.plaidDetailed)
            )

            // saveTransactions restamps lastModifiedAt — exactly right
            // here: the categorization is a local edit that must push.
            let gained = transactions.filter { $0.categoryId != nil }
            if !gained.isEmpty {
                try database.saveTransactions(gained)
                categorizedCount = gained.count
                syncProgress = "Pushing categorizations..."
                await serverSync.push()
            }
        }

        lastSyncSummary = Self.formatStoreSyncSummary(
            pulled: pull.applied,
            categorized: categorizedCount
        )
    }

    /// One-line summary for store-mode syncs. Pure for unit testing.
    static func formatStoreSyncSummary(pulled: Int, categorized: Int) -> String {
        if pulled == 0 {
            return "Up to date — no new transactions"
        }
        var parts = ["\(pulled) pulled from server"]
        if categorized > 0 {
            parts.append("\(categorized) auto-categorized")
        }
        return parts.joined(separator: " · ")
    }

    /// Builds a human-readable one-line summary from sync counters. Pure
    /// so it can be unit-tested without touching the network or DB.
    static func formatSyncSummary(
        added: Int,
        duplicates: Int,
        modified: Int,
        removed: Int,
        pending: Int
    ) -> String {
        if added == 0 && duplicates == 0 && modified == 0 && removed == 0 && pending == 0 {
            return "Up to date — no new transactions"
        }
        var parts: [String] = []
        parts.append("\(added) new")
        if duplicates > 0 {
            parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s") skipped")
        }
        if modified > 0 {
            parts.append("\(modified) updated")
        }
        if removed > 0 {
            parts.append("\(removed) removed")
        }
        if pending > 0 {
            parts.append("\(pending) pending")
        }
        return parts.joined(separator: " · ")
    }

    private func parseDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateString)
    }
}
