import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue

    /// Notify the sync engine that local data has changed.
    private func notifyDataChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .localDataDidChange, object: nil)
        }
    }

    private init() {
        do {
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("BudgetTracking", isDirectory: true)

            try FileManager.default.createDirectory(
                at: appSupportURL, withIntermediateDirectories: true
            )

            let dbURL = appSupportURL.appendingPathComponent("budget.sqlite")
            dbQueue = try DatabaseQueue(path: dbURL.path)
            try runMigrations()
            try seedDefaultCategories()
            try seedDefaultRules()
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    // MARK: - Migrations

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            try db.create(table: "budgetCategory") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("monthlyBudget", .double).notNull().defaults(to: 0)
                t.column("colorHex", .text).notNull().defaults(to: "#4CAF50")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "importedFile") { t in
                t.column("id", .text).primaryKey()
                t.column("fileName", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("month", .text).notNull()
                t.column("transactionCount", .integer).notNull().defaults(to: 0)
                t.column("importedAt", .datetime).notNull()
            }

            try db.create(table: "transaction") { t in
                t.column("id", .text).primaryKey()
                t.column("date", .datetime).notNull()
                t.column("description", .text).notNull()
                t.column("amount", .double).notNull()
                t.column("categoryId", .text).references("budgetCategory", onDelete: .setNull)
                t.column("isManuallyCategorized", .boolean).notNull().defaults(to: false)
                t.column("month", .text).notNull()
                t.column("importedFileId", .text).notNull()
                    .references("importedFile", onDelete: .cascade)
                t.column("importedAt", .datetime).notNull()
            }

            try db.create(table: "categorizationRule") { t in
                t.column("id", .text).primaryKey()
                t.column("keyword", .text).notNull()
                t.column("categoryId", .text).notNull()
                    .references("budgetCategory", onDelete: .cascade)
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("isUserDefined", .boolean).notNull().defaults(to: true)
                t.column("matchCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "monthlySnapshot") { t in
                t.column("id", .text).primaryKey()
                t.column("month", .text).notNull().unique()
                t.column("totalBudget", .double).notNull()
                t.column("totalSpent", .double).notNull()
                t.column("categoryBreakdownData", .blob).notNull()
                t.column("snapshotDate", .datetime).notNull()
            }

            try db.create(table: "bankProfile") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("fileType", .text).notNull()
                t.column("dateColumn", .text)
                t.column("descriptionColumn", .text)
                t.column("amountColumn", .text)
                t.column("debitColumn", .text)
                t.column("creditColumn", .text)
                t.column("dateFormat", .text).notNull().defaults(to: "MM/dd/yyyy")
                t.column("headerRowIndex", .integer).notNull().defaults(to: 0)
                t.column("amountSignConvention", .text).notNull().defaults(to: "negativeIsDebit")
            }

            // Indexes
            try db.create(index: "transaction_month", on: "transaction", columns: ["month"])
            try db.create(index: "transaction_importedFileId", on: "transaction", columns: ["importedFileId"])
            try db.create(index: "importedFile_month", on: "importedFile", columns: ["month"])
        }

        migrator.registerMigration("v2_addMerchantColumn") { db in
            try db.alter(table: "transaction") { t in
                t.add(column: "merchant", .text)
            }
        }

        migrator.registerMigration("v3_optionalImportedFileMonth") { db in
            // Recreate importedFile table with nullable month column
            // to support multi-month files (e.g. yearly Chase activity exports).
            try db.execute(sql: "PRAGMA foreign_keys = OFF")

            try db.create(table: "importedFile_new") { t in
                t.column("id", .text).primaryKey()
                t.column("fileName", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("month", .text) // now nullable for multi-month files
                t.column("transactionCount", .integer).notNull().defaults(to: 0)
                t.column("importedAt", .datetime).notNull()
            }

            try db.execute(sql: "INSERT INTO importedFile_new SELECT * FROM importedFile")
            try db.drop(table: "importedFile")
            try db.rename(table: "importedFile_new", to: "importedFile")
            try db.create(
                index: "importedFile_month", on: "importedFile", columns: ["month"]
            )

            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        migrator.registerMigration("v4_addSyncColumns") { db in
            let tables = [
                "budgetCategory", "transaction", "importedFile",
                "categorizationRule", "monthlySnapshot", "bankProfile"
            ]
            for table in tables {
                try db.alter(table: table) { t in
                    t.add(column: "lastModifiedAt", .datetime)
                    t.add(column: "cloudKitRecordName", .text)
                    t.add(column: "cloudKitSystemFields", .blob)
                    t.add(column: "isDeleted", .boolean).defaults(to: false)
                }

                // Backfill lastModifiedAt for existing rows
                try db.execute(sql: """
                    UPDATE "\(table)" SET lastModifiedAt = CURRENT_TIMESTAMP
                    WHERE lastModifiedAt IS NULL
                    """)

                try db.create(
                    index: "idx_\(table)_lastModified",
                    on: table,
                    columns: ["lastModifiedAt"]
                )
            }

            // Set cloudKitRecordName to id for all existing rows
            for table in tables {
                try db.execute(sql: "UPDATE \"\(table)\" SET cloudKitRecordName = id")
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Seed Data

    private func seedDefaultCategories() throws {
        try dbQueue.write { db in
            let count = try BudgetCategory.fetchCount(db)
            guard count == 0 else { return }
            for category in BudgetCategory.defaultCategories {
                try category.insert(db)
            }
        }
    }

    private func seedDefaultRules() throws {
        try dbQueue.write { db in
            let count = try CategorizationRule.fetchCount(db)
            guard count == 0 else { return }

            // Look up category IDs by name
            let categories = try BudgetCategory.fetchAll(db)
            var categoryByName: [String: UUID] = [:]
            for cat in categories {
                categoryByName[cat.name] = cat.id
            }

            guard let groceries = categoryByName["Groceries"],
                  let dining = categoryByName["Dining Out"],
                  let gas = categoryByName["Gas"],
                  let utilities = categoryByName["Utilities"],
                  let entertainment = categoryByName["Entertainment"],
                  let shopping = categoryByName["Shopping"],
                  let transportation = categoryByName["Transportation"],
                  let health = categoryByName["Health"]
            else { return }

            let defaults: [(String, UUID, Int)] = [
                // Groceries
                ("WHOLE FOODS", groceries, 10),
                ("TRADER JOE", groceries, 10),
                ("KROGER", groceries, 10),
                ("SAFEWAY", groceries, 10),
                ("PUBLIX", groceries, 10),
                ("ALDI", groceries, 10),
                ("COSTCO", groceries, 5),
                ("SAM'S CLUB", groceries, 5),
                ("WALMART GROCERY", groceries, 15),
                ("H-E-B", groceries, 10),
                ("SPROUTS", groceries, 10),
                ("WEGMANS", groceries, 10),
                ("FOOD LION", groceries, 10),
                ("PIGGLY WIGGLY", groceries, 10),
                ("HARRIS TEETER", groceries, 10),
                ("GIANT EAGLE", groceries, 10),
                ("STOP & SHOP", groceries, 10),
                ("WHOLEFDS", groceries, 10),
                ("YAMI.COM", groceries, 10),
                ("BUYER'S MARKET", groceries, 10),

                // Dining Out
                ("STARBUCKS", dining, 10),
                ("MCDONALD", dining, 10),
                ("CHICK-FIL-A", dining, 10),
                ("CHIPOTLE", dining, 10),
                ("PANERA", dining, 10),
                ("SUBWAY", dining, 10),
                ("DUNKIN", dining, 10),
                ("TACO BELL", dining, 10),
                ("WENDY'S", dining, 10),
                ("BURGER KING", dining, 10),
                ("DOMINO", dining, 10),
                ("PIZZA HUT", dining, 10),
                ("GRUBHUB", dining, 10),
                ("DOORDASH", dining, 10),
                ("UBER EATS", dining, 10),
                ("POSTMATES", dining, 10),
                ("IN-N-OUT", dining, 10),
                ("BEN'S PRETZELS", dining, 10),
                ("CA DARIO", dining, 10),
                ("FIRST CLASS CONCESSION", dining, 10),

                // Gas
                ("SHELL", gas, 10),
                ("CHEVRON", gas, 10),
                ("EXXON", gas, 10),
                ("BP ", gas, 10),
                ("MOBIL", gas, 10),
                ("SUNOCO", gas, 10),
                ("SPEEDWAY", gas, 10),
                ("CIRCLE K", gas, 10),
                ("WAWA", gas, 10),
                ("QUIKTRIP", gas, 10),
                ("RACETRAC", gas, 10),
                ("MARATHON", gas, 5),
                ("CITGO", gas, 10),
                ("VALERO", gas, 10),
                ("MAPCO", gas, 10),
                ("AMOCO", gas, 10),

                // Utilities
                ("ELECTRIC", utilities, 5),
                ("WATER BILL", utilities, 5),
                ("GAS BILL", utilities, 10),
                ("INTERNET", utilities, 5),
                ("COMCAST", utilities, 10),
                ("XFINITY", utilities, 10),
                ("AT&T", utilities, 5),
                ("VERIZON", utilities, 5),
                ("T-MOBILE", utilities, 10),
                ("SPECTRUM", utilities, 10),

                // Entertainment
                ("NETFLIX", entertainment, 10),
                ("SPOTIFY", entertainment, 10),
                ("HULU", entertainment, 10),
                ("DISNEY PLUS", entertainment, 10),
                ("APPLE MUSIC", entertainment, 10),
                ("APPLE TV", entertainment, 10),
                ("HBO MAX", entertainment, 10),
                ("YOUTUBE PREMIUM", entertainment, 10),
                ("AMAZON PRIME", entertainment, 10),
                ("AMC THEATRE", entertainment, 10),
                ("AMC ", entertainment, 10),
                ("REGAL CINEMA", entertainment, 10),
                ("XBOX", entertainment, 10),
                ("PLAYSTATION", entertainment, 10),
                ("STEAM", entertainment, 10),
                ("NINTENDO", entertainment, 10),

                // Shopping
                ("AMAZON.COM", shopping, 10),
                ("AMAZON MKTPLACE", shopping, 10),
                ("TARGET", shopping, 10),
                ("WALMART", shopping, 3),
                ("BEST BUY", shopping, 10),
                ("HOME DEPOT", shopping, 10),
                ("LOWE'S", shopping, 10),
                ("IKEA", shopping, 10),
                ("APPLE STORE", shopping, 10),
                ("NORDSTROM", shopping, 10),
                ("MACY'S", shopping, 10),
                ("TJ MAXX", shopping, 10),
                ("MARSHALLS", shopping, 10),
                ("OLD NAVY", shopping, 10),
                ("GAP", shopping, 5),
                ("NIKE", shopping, 10),
                ("ETSY", shopping, 10),
                ("ANTHROPOLOGIE", shopping, 10),
                ("FREE PEOPLE", shopping, 10),
                ("GOODWILL", shopping, 10),
                ("MENARDS", shopping, 10),

                // Transportation
                ("UBER ", transportation, 10),
                ("LYFT", transportation, 10),
                ("PARKING", transportation, 5),
                ("TOLL", transportation, 5),
                ("TRANSIT", transportation, 5),
                ("METRO", transportation, 5),
                ("NATIONAL CAR RENTAL", transportation, 10),
                ("HERTZ", transportation, 10),
                ("ENTERPRISE", transportation, 5),

                // Health
                ("CVS", health, 5),
                ("WALGREENS", health, 5),
                ("PHARMACY", health, 10),
                ("DOCTOR", health, 5),
                ("DENTAL", health, 10),
                ("MEDICAL", health, 5),
                ("HOSPITAL", health, 10),
                ("URGENT CARE", health, 10),
                ("QUEST DIAG", health, 10),
                ("LABCORP", health, 10),
                ("LA FITNESS", health, 10),

                // Utilities / Insurance
                ("PROGRESSIVE", utilities, 10),
                ("NATIONAL GENERAL", utilities, 10),
                ("STATE FARM", utilities, 10),
                ("GEICO", utilities, 10),
                ("ALLSTATE", utilities, 10),
            ]

            for (keyword, categoryId, priority) in defaults {
                let rule = CategorizationRule(
                    keyword: keyword,
                    categoryId: categoryId,
                    priority: priority,
                    isUserDefined: false,
                    matchCount: 0
                )
                try rule.insert(db)
            }
        }
    }

    /// Re-create any default categories that are missing or deleted.
    func restoreDefaultCategories() throws {
        try dbQueue.write { db in
            for defaultCat in BudgetCategory.defaultCategories {
                // Check if a non-deleted category with this name already exists
                let exists = try BudgetCategory
                    .filter(sql: "LOWER(name) = LOWER(?)", arguments: [defaultCat.name])
                    .filter(BudgetCategory.Columns.isDeleted == false)
                    .fetchOne(db)
                if exists == nil {
                    // Un-delete if soft-deleted, otherwise insert fresh
                    if var deleted = try BudgetCategory
                        .filter(sql: "LOWER(name) = LOWER(?)", arguments: [defaultCat.name])
                        .fetchOne(db)
                    {
                        deleted.isDeleted = false
                        deleted.isArchived = false
                        deleted.lastModifiedAt = Date()
                        try deleted.update(db)
                    } else {
                        var cat = defaultCat
                        cat.lastModifiedAt = Date()
                        try cat.insert(db)
                    }
                }
            }
        }
        notifyDataChanged()
    }

    // MARK: - Category Queries

    func fetchCategories() throws -> [BudgetCategory] {
        try dbQueue.read { db in
            try BudgetCategory
                .filter(BudgetCategory.Columns.isArchived == false)
                .filter(BudgetCategory.Columns.isDeleted == false)
                .order(BudgetCategory.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    func saveCategory(_ category: BudgetCategory) throws {
        try dbQueue.write { db in
            var record = category
            record.lastModifiedAt = Date()
            record.cloudKitRecordName = record.cloudKitRecordName ?? record.id.uuidString
            try record.save(db)
        }
        notifyDataChanged()
    }

    func deleteCategory(_ category: BudgetCategory) throws {
        try dbQueue.write { db in
            var archived = category
            archived.isArchived = true
            archived.isDeleted = true
            archived.lastModifiedAt = Date()
            try archived.update(db)
        }
        notifyDataChanged()
    }

    // MARK: - Transaction Queries

    func fetchTransactions(forMonth month: String) throws -> [Transaction] {
        try dbQueue.read { db in
            try Transaction
                .filter(Transaction.Columns.month == month)
                .filter(Transaction.Columns.isDeleted == false)
                .order(Transaction.Columns.date.desc)
                .fetchAll(db)
        }
    }

    func saveTransactions(_ transactions: [Transaction]) throws {
        try dbQueue.write { db in
            for var transaction in transactions {
                transaction.lastModifiedAt = Date()
                transaction.cloudKitRecordName = transaction.cloudKitRecordName ?? transaction.id.uuidString
                try transaction.save(db)
            }
        }
        notifyDataChanged()
    }

    func updateTransactionCategory(
        _ transactionId: UUID, categoryId: UUID, isManual: Bool
    ) throws {
        try dbQueue.write { db in
            if var transaction = try Transaction.fetchOne(
                db, key: transactionId
            ) {
                transaction.categoryId = categoryId
                transaction.isManuallyCategorized = isManual
                transaction.lastModifiedAt = Date()
                try transaction.update(db)
            }
        }
        notifyDataChanged()
    }

    /// Update all transactions in a month whose description or merchant contains the keyword
    /// (case-insensitive). Returns the number of rows updated.
    @discardableResult
    func bulkUpdateCategory(
        matching keyword: String,
        inMonth month: String,
        toCategoryId: UUID,
        excludingTransactionId: UUID
    ) throws -> Int {
        let count = try dbQueue.write { db in
            let pattern = "%\(keyword)%"
            try db.execute(sql: """
                UPDATE "transaction"
                SET categoryId = ?, isManuallyCategorized = 1, lastModifiedAt = ?
                WHERE month = ?
                  AND isDeleted = 0
                  AND (UPPER(description) LIKE UPPER(?)
                       OR UPPER(merchant) LIKE UPPER(?))
                  AND id != ?
                """, arguments: [toCategoryId, Date(), month, pattern, pattern, excludingTransactionId])
            return db.changesCount
        }
        if count > 0 { notifyDataChanged() }
        return count
    }

    func fetchTransactions(forMonth month: String, categoryId: UUID) throws -> [Transaction] {
        try dbQueue.read { db in
            try Transaction
                .filter(Transaction.Columns.month == month)
                .filter(Transaction.Columns.categoryId == categoryId)
                .filter(Transaction.Columns.amount < 0) // only spending
                .filter(Transaction.Columns.isDeleted == false)
                .order(Transaction.Columns.date.desc)
                .fetchAll(db)
        }
    }

    func deleteTransactionsForFile(_ fileId: UUID) throws {
        try dbQueue.write { db in
            // Soft-delete transactions instead of hard delete
            try db.execute(sql: """
                UPDATE "transaction"
                SET isDeleted = 1, lastModifiedAt = ?
                WHERE importedFileId = ?
                """, arguments: [Date(), fileId])
        }
        notifyDataChanged()
    }

    // MARK: - Imported File Queries

    func fetchImportedFiles(forMonth month: String) throws -> [ImportedFile] {
        try dbQueue.read { db in
            // Fetch single-month files for this month, plus any multi-month files
            // that have transactions in this month.
            try ImportedFile.fetchAll(db, sql: """
                SELECT DISTINCT f.*
                FROM importedFile f
                LEFT JOIN "transaction" t ON t.importedFileId = f.id AND t.isDeleted = 0
                WHERE f.isDeleted = 0
                  AND (f.month = ?
                       OR (f.month IS NULL AND t.month = ?))
                ORDER BY f.importedAt DESC
                """, arguments: [month, month])
        }
    }

    func saveImportedFile(_ file: ImportedFile) throws {
        try dbQueue.write { db in
            var record = file
            record.lastModifiedAt = Date()
            record.cloudKitRecordName = record.cloudKitRecordName ?? record.id.uuidString
            try record.save(db)
        }
        notifyDataChanged()
    }

    func deleteImportedFile(_ file: ImportedFile) throws {
        try dbQueue.write { db in
            // Soft-delete the file and its transactions
            try db.execute(sql: """
                UPDATE "transaction"
                SET isDeleted = 1, lastModifiedAt = ?
                WHERE importedFileId = ?
                """, arguments: [Date(), file.id])

            var record = file
            record.isDeleted = true
            record.lastModifiedAt = Date()
            try record.update(db)
        }
        notifyDataChanged()
    }

    func findDuplicateFile(name: String, size: Int64, month: String?) throws -> ImportedFile? {
        try dbQueue.read { db in
            var query = ImportedFile
                .filter(ImportedFile.Columns.fileName == name)
                .filter(ImportedFile.Columns.fileSize == size)
                .filter(ImportedFile.Columns.isDeleted == false)
            if let month {
                query = query.filter(ImportedFile.Columns.month == month)
            } else {
                query = query.filter(ImportedFile.Columns.month == nil)
            }
            return try query.fetchOne(db)
        }
    }

    /// Returns the number of transactions from a specific file that belong to a given month.
    func transactionCount(forFile fileId: UUID, inMonth month: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM "transaction"
                WHERE importedFileId = ? AND month = ? AND isDeleted = 0
                """, arguments: [fileId, month]) ?? 0
        }
    }

    // MARK: - Spending Aggregation

    func fetchSpendingByCategory(forMonth month: String) throws -> [UUID: Double] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT categoryId, SUM(amount) as total
                FROM "transaction"
                WHERE month = ? AND amount < 0 AND isDeleted = 0
                GROUP BY categoryId
                """, arguments: [month])

            var result: [UUID: Double] = [:]
            for row in rows {
                if let id: UUID = row["categoryId"] {
                    result[id] = abs(row["total"] ?? 0.0)
                }
            }
            return result
        }
    }

    func fetchTotalSpending(forMonth month: String) throws -> Double {
        try dbQueue.read { db in
            let total = try Double.fetchOne(db, sql: """
                SELECT SUM(amount) FROM "transaction"
                WHERE month = ? AND amount < 0 AND isDeleted = 0
                """, arguments: [month])
            return abs(total ?? 0.0)
        }
    }

    // MARK: - Categorization Rules

    func fetchRules() throws -> [CategorizationRule] {
        try dbQueue.read { db in
            try CategorizationRule
                .filter(CategorizationRule.Columns.isDeleted == false)
                .order(CategorizationRule.Columns.priority.desc)
                .fetchAll(db)
        }
    }

    func saveRule(_ rule: CategorizationRule) throws {
        try dbQueue.write { db in
            var record = rule
            record.lastModifiedAt = Date()
            record.cloudKitRecordName = record.cloudKitRecordName ?? record.id.uuidString
            try record.save(db)
        }
        notifyDataChanged()
    }

    func deleteRule(_ rule: CategorizationRule) throws {
        try dbQueue.write { db in
            var record = rule
            record.isDeleted = true
            record.lastModifiedAt = Date()
            try record.update(db)
        }
        notifyDataChanged()
    }

    func incrementRuleMatchCount(_ ruleId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE categorizationRule SET matchCount = matchCount + 1, lastModifiedAt = ?
                WHERE id = ?
                """, arguments: [Date(), ruleId])
        }
        notifyDataChanged()
    }

    // MARK: - Bank Profiles

    func fetchBankProfiles() throws -> [BankProfile] {
        try dbQueue.read { db in
            try BankProfile.fetchAll(db)
        }
    }

    func saveBankProfile(_ profile: BankProfile) throws {
        try dbQueue.write { db in
            var record = profile
            record.lastModifiedAt = Date()
            record.cloudKitRecordName = record.cloudKitRecordName ?? record.id.uuidString
            try record.save(db)
        }
        notifyDataChanged()
    }

    // MARK: - Monthly Snapshots

    func fetchSnapshot(forMonth month: String) throws -> MonthlySnapshot? {
        try dbQueue.read { db in
            try MonthlySnapshot
                .filter(MonthlySnapshot.Columns.month == month)
                .filter(MonthlySnapshot.Columns.isDeleted == false)
                .fetchOne(db)
        }
    }

    func saveSnapshot(_ snapshot: MonthlySnapshot) throws {
        try dbQueue.write { db in
            // Upsert: soft-delete old snapshot for this month, insert new
            try db.execute(sql: """
                UPDATE monthlySnapshot
                SET isDeleted = 1, lastModifiedAt = ?
                WHERE month = ?
                """, arguments: [Date(), snapshot.month])
            var record = snapshot
            record.lastModifiedAt = Date()
            record.cloudKitRecordName = record.cloudKitRecordName ?? record.id.uuidString
            try record.insert(db)
        }
        notifyDataChanged()
    }

    func fetchAllSnapshotMonths() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT month FROM "transaction"
                WHERE isDeleted = 0
                ORDER BY month DESC
                """)
        }
    }

    // MARK: - Sync Queries

    /// Fetch all records of a given table that have been modified since a date
    /// OR have never been synced to CloudKit (cloudKitRecordName IS NULL).
    func fetchPendingChanges<T: FetchableRecord & TableRecord>(
        type: T.Type, since: Date
    ) throws -> [T] {
        try dbQueue.read { db in
            try T.filter(sql: "lastModifiedAt > ? OR cloudKitRecordName IS NULL", arguments: [since]).fetchAll(db)
        }
    }

    /// Fetch all soft-deleted records of a given table.
    func fetchSoftDeleted<T: FetchableRecord & TableRecord>(
        type: T.Type
    ) throws -> [T] {
        try dbQueue.read { db in
            try T.filter(sql: "isDeleted = 1").fetchAll(db)
        }
    }

    /// Upsert a record received from CloudKit (insert or replace).
    func upsertFromCloud<T: PersistableRecord>(_ record: T) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    /// Hard-delete a record after confirming the deletion has been synced.
    func hardDelete(table: String, recordName: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM "\(table)" WHERE cloudKitRecordName = ?
                """, arguments: [recordName])
        }
    }

    // MARK: - LAN Sync Queries

    /// Fetch all records modified since a given date (including soft-deleted ones for sync).
    func fetchAllRecords<T: FetchableRecord & TableRecord>(
        type: T.Type, since: Date
    ) throws -> [T] {
        try dbQueue.read { db in
            try T.filter(sql: "lastModifiedAt > ?", arguments: [since]).fetchAll(db)
        }
    }

    /// Upsert a record received from a LAN peer with conflict-aware merge (generic fallback).
    /// Returns true if the record was actually applied (incoming was newer).
    @discardableResult
    func upsertFromPeer<T: PersistableRecord & FetchableRecord & Identifiable & Codable>(
        _ incoming: T
    ) throws -> Bool where T.ID == UUID {
        try dbQueue.write { db in
            try Self.applyPeerRecord(incoming, existing: try T.fetchOne(db, key: incoming.id), in: db)
        }
    }

    // MARK: - Type-Specific Upserts (content-based deduplication)

    /// Upsert a BudgetCategory with dedup on `name`.
    @discardableResult
    func upsertFromPeer(_ incoming: BudgetCategory) throws -> Bool {
        try dbQueue.write { db in
            // 1. Exact UUID match
            if let existing = try BudgetCategory.fetchOne(db, key: incoming.id) {
                return try Self.applyPeerRecord(incoming, existing: existing, in: db)
            }
            // 2. Content-based match: same name (case-insensitive)
            if let existing = try BudgetCategory
                .filter(sql: "LOWER(name) = LOWER(?)", arguments: [incoming.name])
                .filter(BudgetCategory.Columns.isDeleted == false)
                .fetchOne(db)
            {
                // Remap any references from incoming.id → existing.id
                try Self.remapCategoryId(from: incoming.id, to: existing.id, in: db)
                // Merge using existing's UUID
                var merged = incoming
                merged.id = existing.id
                return try Self.applyPeerRecord(merged, existing: existing, in: db)
            }
            // 3. New record
            return try Self.applyPeerRecord(incoming, existing: nil, in: db)
        }
    }

    /// Upsert a Transaction with dedup on `(date, description, amount, month)`.
    @discardableResult
    func upsertFromPeer(_ incoming: Transaction) throws -> Bool {
        try dbQueue.write { db in
            // 1. Exact UUID match
            if let existing = try Transaction.fetchOne(db, key: incoming.id) {
                return try Self.applyPeerTransaction(incoming, existing: existing, in: db)
            }
            // 2. Content-based match
            if let existing = try Transaction
                .filter(Transaction.Columns.date == incoming.date)
                .filter(Transaction.Columns.description == incoming.description)
                .filter(Transaction.Columns.amount == incoming.amount)
                .filter(Transaction.Columns.month == incoming.month)
                .filter(Transaction.Columns.isDeleted == false)
                .fetchOne(db)
            {
                var merged = incoming
                merged.id = existing.id
                return try Self.applyPeerTransaction(merged, existing: existing, in: db)
            }
            // 3. New record
            return try Self.applyPeerTransaction(incoming, existing: nil, in: db)
        }
    }

    /// Upsert an ImportedFile with dedup on `(fileName, fileSize)`.
    @discardableResult
    func upsertFromPeer(_ incoming: ImportedFile) throws -> Bool {
        try dbQueue.write { db in
            if let existing = try ImportedFile.fetchOne(db, key: incoming.id) {
                return try Self.applyPeerRecord(incoming, existing: existing, in: db)
            }
            if let existing = try ImportedFile
                .filter(ImportedFile.Columns.fileName == incoming.fileName)
                .filter(ImportedFile.Columns.fileSize == incoming.fileSize)
                .filter(ImportedFile.Columns.isDeleted == false)
                .fetchOne(db)
            {
                var merged = incoming
                merged.id = existing.id
                return try Self.applyPeerRecord(merged, existing: existing, in: db)
            }
            return try Self.applyPeerRecord(incoming, existing: nil, in: db)
        }
    }

    /// Upsert a CategorizationRule with dedup on `(keyword, categoryId)`.
    @discardableResult
    func upsertFromPeer(_ incoming: CategorizationRule) throws -> Bool {
        try dbQueue.write { db in
            if let existing = try CategorizationRule.fetchOne(db, key: incoming.id) {
                return try Self.applyPeerRecord(incoming, existing: existing, in: db)
            }
            if let existing = try CategorizationRule
                .filter(sql: "LOWER(keyword) = LOWER(?)", arguments: [incoming.keyword])
                .filter(CategorizationRule.Columns.categoryId == incoming.categoryId)
                .filter(CategorizationRule.Columns.isDeleted == false)
                .fetchOne(db)
            {
                var merged = incoming
                merged.id = existing.id
                return try Self.applyPeerRecord(merged, existing: existing, in: db)
            }
            return try Self.applyPeerRecord(incoming, existing: nil, in: db)
        }
    }

    /// Upsert a MonthlySnapshot with dedup on `month`.
    @discardableResult
    func upsertFromPeer(_ incoming: MonthlySnapshot) throws -> Bool {
        try dbQueue.write { db in
            if let existing = try MonthlySnapshot.fetchOne(db, key: incoming.id) {
                return try Self.applyPeerRecord(incoming, existing: existing, in: db)
            }
            if let existing = try MonthlySnapshot
                .filter(MonthlySnapshot.Columns.month == incoming.month)
                .filter(MonthlySnapshot.Columns.isDeleted == false)
                .fetchOne(db)
            {
                var merged = incoming
                merged.id = existing.id
                return try Self.applyPeerRecord(merged, existing: existing, in: db)
            }
            return try Self.applyPeerRecord(incoming, existing: nil, in: db)
        }
    }

    /// Upsert a BankProfile with dedup on `name`.
    @discardableResult
    func upsertFromPeer(_ incoming: BankProfile) throws -> Bool {
        try dbQueue.write { db in
            if let existing = try BankProfile.fetchOne(db, key: incoming.id) {
                return try Self.applyPeerRecord(incoming, existing: existing, in: db)
            }
            if let existing = try BankProfile
                .filter(sql: "LOWER(name) = LOWER(?)", arguments: [incoming.name])
                .filter(BankProfile.Columns.isDeleted == false)
                .fetchOne(db)
            {
                var merged = incoming
                merged.id = existing.id
                return try Self.applyPeerRecord(merged, existing: existing, in: db)
            }
            return try Self.applyPeerRecord(incoming, existing: nil, in: db)
        }
    }

    // MARK: - Shared Peer Sync Helpers

    /// Core last-writer-wins merge logic shared by all upsert overloads.
    private static func applyPeerRecord<T: PersistableRecord & FetchableRecord & Identifiable & Codable>(
        _ incoming: T, existing: T?, in db: Database
    ) throws -> Bool where T.ID == UUID {
        if let existing {
            let existingModified = Mirror(reflecting: existing)
                .children.first(where: { $0.label == "lastModifiedAt" })?.value as? Date ?? .distantPast
            let incomingModified = Mirror(reflecting: incoming)
                .children.first(where: { $0.label == "lastModifiedAt" })?.value as? Date ?? .distantPast
            guard incomingModified > existingModified else {
                return false
            }
        }
        let record = incoming
        if var mutableRecord = record as? (any MutablePersistableRecord) {
            try mutableRecord.save(db)
            return true
        }
        try record.save(db)
        return true
    }

    /// Transaction-specific merge that also protects manually categorized records.
    private static func applyPeerTransaction(
        _ incoming: Transaction, existing: Transaction?, in db: Database
    ) throws -> Bool {
        if let existing {
            guard incoming.lastModifiedAt > existing.lastModifiedAt else {
                return false
            }
            // Prefer manually categorized version
            if existing.isManuallyCategorized && !incoming.isManuallyCategorized {
                return false
            }
        }
        var txn = incoming
        try txn.save(db)
        return true
    }

    /// Remap all references from one categoryId to another (used when merging duplicate categories).
    private static func remapCategoryId(from oldId: UUID, to newId: UUID, in db: Database) throws {
        // Update transactions
        try db.execute(
            sql: "UPDATE \"transaction\" SET categoryId = ? WHERE categoryId = ?",
            arguments: [newId, oldId]
        )
        // Update categorization rules
        try db.execute(
            sql: "UPDATE \"categorizationRule\" SET categoryId = ? WHERE categoryId = ?",
            arguments: [newId, oldId]
        )
    }

    /// Purge soft-deleted records older than a given date (after sync confirmation).
    func purgeDeletedRecords(olderThan date: Date) throws {
        let tables = [
            "budgetCategory", "transaction", "importedFile",
            "categorizationRule", "monthlySnapshot", "bankProfile"
        ]
        try dbQueue.write { db in
            for table in tables {
                try db.execute(sql: """
                    DELETE FROM "\(table)"
                    WHERE isDeleted = 1 AND lastModifiedAt < ?
                    """, arguments: [date])
            }
        }
    }
}
