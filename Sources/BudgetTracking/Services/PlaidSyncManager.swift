import Foundation
import SwiftUI

@Observable
final class PlaidSyncManager {
    var isSyncing = false
    var syncProgress: String = ""
    var errorMessage: String?
    var linkedAccounts: [PlaidAccount] = []

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

            // Sync server accounts to local DB
            for account in serverAccounts {
                let plaidAccount = PlaidAccount(
                    plaidAccountId: account.plaid_account_id,
                    plaidItemId: account.plaid_item_id,
                    institutionName: account.institution_name,
                    name: account.name,
                    officialName: account.official_name,
                    type: account.type,
                    subtype: account.subtype,
                    mask: account.mask
                )
                try DatabaseManager.shared.savePlaidAccount(plaidAccount)
            }

            loadAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
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
