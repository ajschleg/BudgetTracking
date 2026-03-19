import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue

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

    // MARK: - Category Queries

    func fetchCategories() throws -> [BudgetCategory] {
        try dbQueue.read { db in
            try BudgetCategory
                .filter(BudgetCategory.Columns.isArchived == false)
                .order(BudgetCategory.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    func saveCategory(_ category: BudgetCategory) throws {
        try dbQueue.write { db in
            try category.save(db)
        }
    }

    func deleteCategory(_ category: BudgetCategory) throws {
        try dbQueue.write { db in
            var archived = category
            archived.isArchived = true
            try archived.update(db)
        }
    }

    // MARK: - Transaction Queries

    func fetchTransactions(forMonth month: String) throws -> [Transaction] {
        try dbQueue.read { db in
            try Transaction
                .filter(Transaction.Columns.month == month)
                .order(Transaction.Columns.date.desc)
                .fetchAll(db)
        }
    }

    func saveTransactions(_ transactions: [Transaction]) throws {
        try dbQueue.write { db in
            for transaction in transactions {
                try transaction.save(db)
            }
        }
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
                try transaction.update(db)
            }
        }
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
        try dbQueue.write { db in
            let pattern = "%\(keyword)%"
            try db.execute(sql: """
                UPDATE "transaction"
                SET categoryId = ?, isManuallyCategorized = 1
                WHERE month = ?
                  AND (UPPER(description) LIKE UPPER(?)
                       OR UPPER(merchant) LIKE UPPER(?))
                  AND id != ?
                """, arguments: [toCategoryId, month, pattern, pattern, excludingTransactionId])
            return db.changesCount
        }
    }

    func deleteTransactionsForFile(_ fileId: UUID) throws {
        try dbQueue.write { db in
            try Transaction
                .filter(Transaction.Columns.importedFileId == fileId)
                .deleteAll(db)
        }
    }

    // MARK: - Imported File Queries

    func fetchImportedFiles(forMonth month: String) throws -> [ImportedFile] {
        try dbQueue.read { db in
            // Fetch single-month files for this month, plus any multi-month files
            // that have transactions in this month.
            try ImportedFile.fetchAll(db, sql: """
                SELECT DISTINCT f.*
                FROM importedFile f
                LEFT JOIN "transaction" t ON t.importedFileId = f.id
                WHERE f.month = ?
                   OR (f.month IS NULL AND t.month = ?)
                ORDER BY f.importedAt DESC
                """, arguments: [month, month])
        }
    }

    func saveImportedFile(_ file: ImportedFile) throws {
        try dbQueue.write { db in
            try file.save(db)
        }
    }

    func deleteImportedFile(_ file: ImportedFile) throws {
        // Transactions are cascade-deleted via FK
        try dbQueue.write { db in
            try file.delete(db)
        }
    }

    func findDuplicateFile(name: String, size: Int64, month: String?) throws -> ImportedFile? {
        try dbQueue.read { db in
            var query = ImportedFile
                .filter(ImportedFile.Columns.fileName == name)
                .filter(ImportedFile.Columns.fileSize == size)
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
                WHERE importedFileId = ? AND month = ?
                """, arguments: [fileId, month]) ?? 0
        }
    }

    // MARK: - Spending Aggregation

    func fetchSpendingByCategory(forMonth month: String) throws -> [UUID: Double] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT categoryId, SUM(amount) as total
                FROM "transaction"
                WHERE month = ? AND amount < 0
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
                WHERE month = ? AND amount < 0
                """, arguments: [month])
            return abs(total ?? 0.0)
        }
    }

    // MARK: - Categorization Rules

    func fetchRules() throws -> [CategorizationRule] {
        try dbQueue.read { db in
            try CategorizationRule
                .order(CategorizationRule.Columns.priority.desc)
                .fetchAll(db)
        }
    }

    func saveRule(_ rule: CategorizationRule) throws {
        try dbQueue.write { db in
            try rule.save(db)
        }
    }

    func deleteRule(_ rule: CategorizationRule) throws {
        try dbQueue.write { db in
            try rule.delete(db)
        }
    }

    func incrementRuleMatchCount(_ ruleId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE categorizationRule SET matchCount = matchCount + 1
                WHERE id = ?
                """, arguments: [ruleId])
        }
    }

    // MARK: - Bank Profiles

    func fetchBankProfiles() throws -> [BankProfile] {
        try dbQueue.read { db in
            try BankProfile.fetchAll(db)
        }
    }

    func saveBankProfile(_ profile: BankProfile) throws {
        try dbQueue.write { db in
            try profile.save(db)
        }
    }

    // MARK: - Monthly Snapshots

    func fetchSnapshot(forMonth month: String) throws -> MonthlySnapshot? {
        try dbQueue.read { db in
            try MonthlySnapshot
                .filter(MonthlySnapshot.Columns.month == month)
                .fetchOne(db)
        }
    }

    func saveSnapshot(_ snapshot: MonthlySnapshot) throws {
        try dbQueue.write { db in
            // Upsert: delete old snapshot for this month, insert new
            try MonthlySnapshot
                .filter(MonthlySnapshot.Columns.month == snapshot.month)
                .deleteAll(db)
            try snapshot.insert(db)
        }
    }

    func fetchAllSnapshotMonths() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT month FROM "transaction"
                ORDER BY month DESC
                """)
        }
    }
}
