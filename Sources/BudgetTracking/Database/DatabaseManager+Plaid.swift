import Foundation
import GRDB

// MARK: - Plaid Account Queries

extension DatabaseManager {

    func fetchPlaidAccounts() throws -> [PlaidAccount] {
        try dbQueue.read { db in
            try PlaidAccount
                .filter(PlaidAccount.Columns.isDeleted == false)
                .order(PlaidAccount.Columns.institutionName, PlaidAccount.Columns.name)
                .fetchAll(db)
        }
    }

    func savePlaidAccount(_ account: PlaidAccount) throws {
        try dbQueue.write { db in
            var record = account
            // Upsert by plaidAccountId
            if let existing = try PlaidAccount
                .filter(PlaidAccount.Columns.plaidAccountId == account.plaidAccountId)
                .fetchOne(db) {
                record.id = existing.id
            }
            record.lastModifiedAt = Date()
            try record.save(db)
        }
    }

    func deletePlaidAccounts(forItemId itemId: String) throws {
        try dbQueue.write { db in
            try PlaidAccount
                .filter(PlaidAccount.Columns.plaidItemId == itemId)
                .deleteAll(db)
        }
    }

    /// Update balance fields on a PlaidAccount row identified by the
    /// Plaid account_id. Silent no-op if the row is missing.
    func updatePlaidAccountBalance(
        plaidAccountId: String,
        current: Double?,
        available: Double?,
        limit: Double?,
        currencyCode: String?,
        fetchedAt: Date
    ) throws {
        try dbQueue.write { db in
            guard var account = try PlaidAccount
                .filter(PlaidAccount.Columns.plaidAccountId == plaidAccountId)
                .fetchOne(db) else { return }

            account.balanceCurrent = current
            account.balanceAvailable = available
            account.balanceLimit = limit
            account.balanceCurrencyCode = currencyCode
            account.balanceFetchedAt = fetchedAt
            account.lastModifiedAt = fetchedAt
            try account.update(db)
        }
    }

    // MARK: - Transaction Deduplication

    func transactionExists(externalId: String) throws -> Bool {
        try dbQueue.read { db in
            let count = try Transaction
                .filter(Transaction.Columns.externalId == externalId)
                .filter(Transaction.Columns.isDeleted == false)
                .fetchCount(db)
            return count > 0
        }
    }

    func updateTransactionByExternalId(
        externalId: String,
        description: String,
        merchant: String?,
        amount: Double,
        date: Date
    ) throws {
        try dbQueue.write { db in
            guard var transaction = try Transaction
                .filter(Transaction.Columns.externalId == externalId)
                .filter(Transaction.Columns.isDeleted == false)
                .fetchOne(db) else { return }

            // Only update if not manually categorized (preserve user edits)
            if !transaction.isManuallyCategorized {
                transaction.description = description
                transaction.merchant = merchant
            }
            transaction.amount = amount
            transaction.date = date
            transaction.month = DateHelpers.monthString(from: date)
            transaction.lastModifiedAt = Date()
            try transaction.update(db)
        }
    }

    func softDeleteTransactionByExternalId(_ externalId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE "transaction" SET isDeleted = 1, lastModifiedAt = ?
                    WHERE externalId = ? AND isDeleted = 0
                    """,
                arguments: [Date(), externalId]
            )
        }
    }

    // MARK: - Import Duplicate Detection

    /// Find Plaid-synced transactions that match a given date and amount (within tolerance).
    /// Used during manual import to detect transactions already pulled via Plaid.
    func findPlaidDuplicate(date: Date, amount: Double, description: String) throws -> Transaction? {
        try dbQueue.read { db in
            // Match by date (same day) and exact amount, must have an externalId (Plaid-sourced)
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: date)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

            return try Transaction
                .filter(Transaction.Columns.externalId != nil)
                .filter(Transaction.Columns.isDeleted == false)
                .filter(Transaction.Columns.date >= startOfDay && Transaction.Columns.date < endOfDay)
                .filter(Transaction.Columns.amount == amount)
                .fetchOne(db)
        }
    }
}
