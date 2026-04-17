import Foundation
import SwiftUI

@Observable
final class PlaidSyncManager {
    var isSyncing = false
    var syncProgress: String = ""
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

    private let plaidService = PlaidService()

    // MARK: - Account Management

    func loadAccounts() {
        do {
            linkedAccounts = try DatabaseManager.shared.fetchPlaidAccounts()
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
                try DatabaseManager.shared.savePlaidAccount(plaidAccount)
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
            try DatabaseManager.shared.deletePlaidAccounts(forItemId: account.plaidItemId)
            loadAccounts()
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
            let response = try await plaidService.refreshBalances()

            // Persist fresh balances to the local DB
            let fetchedAt = Date()
            for item in response.refreshed {
                for acct in item.accounts {
                    try? DatabaseManager.shared.updatePlaidAccountBalance(
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
    func startUpdateMode(for itemId: String) {
        pendingUpdateItemId = itemId
    }

    /// Called when update-mode Link finishes (success or exit).
    func finishUpdateMode() {
        pendingUpdateItemId = nil
        Task { await refreshUpdateModeStatus() }
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
            let response = try await plaidService.refreshIdentity()
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
            try? DatabaseManager.shared.savePlaidAccount(plaidAccount)
        }
        loadAccounts()

        // The server auto-fetched identity during /link/exchange — pull
        // the enriched rows (with owner_name etc.) back to the device.
        Task { await refreshAccountsFromServer() }
    }

    // MARK: - Transaction Sync

    func syncTransactions() async {
        isSyncing = true
        syncProgress = "Syncing transactions..."
        errorMessage = nil

        defer {
            isSyncing = false
            syncProgress = ""
        }

        do {
            let response = try await plaidService.syncTransactions()

            // Create a synthetic ImportedFile for this sync batch
            let importedFile = ImportedFile(
                fileName: "Plaid Sync \(DateHelpers.monthString())",
                fileSize: 0,
                month: nil,
                transactionCount: response.added.count + response.modified.count
            )
            try DatabaseManager.shared.saveImportedFile(importedFile)

            // Process added transactions
            if !response.added.isEmpty {
                syncProgress = "Saving \(response.added.count) new transactions..."
                var transactions: [Transaction] = []

                for plaidTxn in response.added {
                    // Skip pending transactions
                    guard !plaidTxn.pending else { continue }

                    // Check for duplicates by externalId
                    if try DatabaseManager.shared.transactionExists(externalId: plaidTxn.transaction_id) {
                        continue
                    }

                    let date = parseDate(plaidTxn.date) ?? Date()
                    let month = DateHelpers.monthString(from: date)

                    let transaction = Transaction(
                        date: date,
                        description: plaidTxn.merchant_name ?? plaidTxn.name,
                        merchant: plaidTxn.merchant_name,
                        amount: -plaidTxn.amount, // Flip sign: Plaid positive = expense, app negative = expense
                        month: month,
                        importedFileId: importedFile.id,
                        externalId: plaidTxn.transaction_id
                    )
                    transactions.append(transaction)
                }

                if !transactions.isEmpty {
                    // Auto-categorize before saving
                    syncProgress = "Categorizing transactions..."
                    let rules = try DatabaseManager.shared.fetchRules()
                    let categories = try DatabaseManager.shared.fetchCategories()
                    let engine = CategorizationEngine(rules: rules, categories: categories)
                    engine.categorizeAll(transactions: &transactions)

                    try DatabaseManager.shared.saveTransactions(transactions)
                }
            }

            // Process modified transactions
            if !response.modified.isEmpty {
                syncProgress = "Updating \(response.modified.count) transactions..."
                for plaidTxn in response.modified {
                    guard !plaidTxn.pending else { continue }
                    try DatabaseManager.shared.updateTransactionByExternalId(
                        externalId: plaidTxn.transaction_id,
                        description: plaidTxn.merchant_name ?? plaidTxn.name,
                        merchant: plaidTxn.merchant_name,
                        amount: -plaidTxn.amount,
                        date: parseDate(plaidTxn.date) ?? Date()
                    )
                }
            }

            // Process removed transactions
            if !response.removed.isEmpty {
                syncProgress = "Removing \(response.removed.count) transactions..."
                for removed in response.removed {
                    try DatabaseManager.shared.softDeleteTransactionByExternalId(removed.transaction_id)
                }
            }

            let total = response.added.count + response.modified.count + response.removed.count
            if total > 0 {
                DatabaseManager.shared.notifyDataChanged()
            }

            syncProgress = "Sync complete"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateString)
    }
}
