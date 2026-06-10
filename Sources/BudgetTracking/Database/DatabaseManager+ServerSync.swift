import Foundation
import GRDB

/// Server-hub sync support (the server's transactions table is the source
/// of truth; this device's GRDB copy is a cache). Applying pulled rows and
/// gathering rows for push/seed both live here.
extension DatabaseManager {

    /// Identity of the singleton ImportedFile that hosts server rows with
    /// no imported_file_id (Plaid rows ingested server-side). Fixed UUID so
    /// every device converges on the same row — ImportedFile itself still
    /// syncs via CloudKit/LAN, and the local schema requires every
    /// transaction to reference one (NOT NULL + ON DELETE CASCADE).
    static let serverSyncFileId = UUID(uuidString: "B0BCA5E5-0000-4000-8000-5E22E25E25E2")!

    struct ServerApplyOutcome {
        var applied = 0
        var skipped = 0
        /// Newly inserted, uncategorized, live Plaid rows with their Plaid
        /// category hints riding along (the local model has no plaid_category
        /// columns) — the caller runs CategorizationEngine over these.
        var needsCategorization: [(transaction: Transaction, plaidPrimary: String?, plaidDetailed: String?)] = []
        /// Server stamps applied this batch (id → lastModifiedAt). Push uses
        /// these to recognize rows that merely round-tripped from the server
        /// and skip re-sending them.
        var appliedStamps: [UUID: Date] = [:]
    }

    /// Fold one page of server changes into the local cache, in a single
    /// write transaction. Merge rules mirror upsertFromPeer(Transaction):
    /// match by id, then by externalId (unique locally, tombstones
    /// included so a user deletion never resurrects); last-write-wins on
    /// timestamps; an incoming non-manual row never overwrites a manually
    /// categorized one.
    ///
    /// Echo prevention: rows are written with `lastModifiedAt` set to the
    /// SERVER's updated_at via direct save — never through
    /// saveTransactions(), which restamps Date() and would mark every
    /// pulled row dirty for the next push, looping forever.
    func applyServerChanges(_ changes: [PlaidService.ServerTransactionChange]) throws -> ServerApplyOutcome {
        var outcome = ServerApplyOutcome()
        guard !changes.isEmpty else { return outcome }

        try dbQueue.write { db in
            for change in changes {
                guard let parsedId = UUID(uuidString: change.id) else {
                    outcome.skipped += 1
                    continue
                }
                let updatedAt = Self.parseServerTimestamp(change.updated_at) ?? Date()

                // Resolve the ImportedFile FK: singleton for server-ingested
                // rows, placeholder for files this device never saw. The
                // placeholders are plain live rows (never tombstoned), so
                // tombstone purges can't cascade away pulled history.
                let fileId = change.imported_file_id.flatMap(UUID.init(uuidString:)) ?? Self.serverSyncFileId
                if try ImportedFile.fetchOne(db, key: fileId) == nil {
                    var placeholder = ImportedFile(
                        id: fileId,
                        fileName: fileId == Self.serverSyncFileId ? "Server Sync" : "Synced import",
                        fileSize: 0,
                        month: nil,
                        transactionCount: 0
                    )
                    try placeholder.save(db)
                }

                // Categories still sync via CloudKit, which can lag the
                // server pull — a transaction may reference a category this
                // device hasn't received yet. Materialize a placeholder with
                // an epoch lastModifiedAt so the real CloudKit record always
                // wins the LWW merge and fixes the name when it lands.
                // (Without this, the categoryId FK rejects the whole row.)
                let categoryId = change.category_id.flatMap(UUID.init(uuidString:))
                if let categoryId, try BudgetCategory.fetchOne(db, key: categoryId) == nil {
                    var placeholder = BudgetCategory(
                        id: categoryId,
                        name: "(syncing…)",
                        monthlyBudget: 0,
                        colorHex: "#9E9E9E",
                        sortOrder: 98,
                        lastModifiedAt: Date(timeIntervalSince1970: 0)
                    )
                    try placeholder.save(db)
                }

                var existing = try Transaction.fetchOne(db, key: parsedId)
                if existing == nil, let externalId = change.external_id, !externalId.isEmpty {
                    existing = try Transaction
                        .filter(Transaction.Columns.externalId == externalId)
                        .fetchOne(db)
                }

                if let existing {
                    guard updatedAt > existing.lastModifiedAt else {
                        outcome.skipped += 1
                        continue
                    }
                    if existing.isManuallyCategorized && !change.is_manually_categorized {
                        outcome.skipped += 1
                        continue
                    }
                }

                var transaction = Transaction(
                    id: existing?.id ?? parsedId,
                    date: Self.parseServerDate(change.date) ?? existing?.date ?? Date(),
                    description: change.description,
                    merchant: change.merchant,
                    amount: change.amount,
                    categoryId: categoryId,
                    isManuallyCategorized: change.is_manually_categorized,
                    month: change.month,
                    importedFileId: fileId,
                    importedAt: existing?.importedAt ?? Date(),
                    externalId: change.external_id,
                    lastModifiedAt: updatedAt,
                    cloudKitRecordName: existing?.cloudKitRecordName,
                    cloudKitSystemFields: existing?.cloudKitSystemFields,
                    isDeleted: change.is_deleted
                )
                try transaction.save(db)

                outcome.applied += 1
                outcome.appliedStamps[transaction.id] = updatedAt
                if existing == nil, transaction.categoryId == nil, !transaction.isDeleted, change.source == "plaid" {
                    outcome.needsCategorization.append((transaction, change.plaid_category, change.plaid_category_detailed))
                }
            }
        }
        return outcome
    }

    /// Every transaction including tombstones — the seed payload and the
    /// "N transactions" count behind the Settings upload button.
    func fetchAllTransactionsIncludingDeleted() throws -> [Transaction] {
        try fetchAllRecords(type: Transaction.self, since: .distantPast)
    }

    // MARK: - Server wire-format helpers

    /// "yyyy-MM-dd" in the device's timezone — the exact behavior of the
    /// pre-hub Plaid import path, so months keep grouping identically.
    private static let serverDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// ISO-8601 with fractional seconds — the server stamps updated_at via
    /// strftime('%Y-%m-%dT%H:%M:%fZ').
    private static let serverTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseServerDate(_ string: String) -> Date? {
        serverDateFormatter.date(from: string)
    }

    static func serverDateString(from date: Date) -> String {
        serverDateFormatter.string(from: date)
    }

    static func parseServerTimestamp(_ string: String) -> Date? {
        serverTimestampFormatter.date(from: string)
            ?? ISO8601DateFormatter().date(from: string)  // tolerate no-fraction stamps
    }
}
