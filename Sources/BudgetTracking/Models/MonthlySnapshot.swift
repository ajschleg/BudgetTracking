import Foundation
import GRDB

struct MonthlySnapshot: Identifiable, Codable, Equatable {
    var id: UUID
    var month: String // "2026-03"
    var totalBudget: Double
    var totalSpent: Double
    var categoryBreakdownData: Data // JSON-encoded [CategorySummary]
    var snapshotDate: Date

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        month: String,
        totalBudget: Double,
        totalSpent: Double,
        categoryBreakdown: [CategorySummary],
        snapshotDate: Date = Date(),
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.month = month
        self.totalBudget = totalBudget
        self.totalSpent = totalSpent
        self.categoryBreakdownData = (try? JSONEncoder().encode(categoryBreakdown)) ?? Data()
        self.snapshotDate = snapshotDate
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }

    var categoryBreakdown: [CategorySummary] {
        (try? JSONDecoder().decode([CategorySummary].self, from: categoryBreakdownData)) ?? []
    }
}

struct CategorySummary: Codable, Equatable {
    var categoryName: String
    var colorHex: String
    var budgetAmount: Double
    var spentAmount: Double
    var transactionCount: Int

    var percentage: Double {
        guard budgetAmount > 0 else { return spentAmount > 0 ? 1.0 : 0.0 }
        return spentAmount / budgetAmount
    }
}

extension MonthlySnapshot: FetchableRecord, PersistableRecord {
    static let databaseTableName = "monthlySnapshot"

    enum Columns: String, ColumnExpression {
        case id, month, totalBudget, totalSpent, categoryBreakdownData, snapshotDate
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
