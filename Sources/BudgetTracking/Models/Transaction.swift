import Foundation
import GRDB

struct Transaction: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var description: String
    var amount: Double
    var categoryId: UUID?
    var isManuallyCategorized: Bool
    var month: String // "2026-03"
    var importedFileId: UUID
    var importedAt: Date

    init(
        id: UUID = UUID(),
        date: Date,
        description: String,
        amount: Double,
        categoryId: UUID? = nil,
        isManuallyCategorized: Bool = false,
        month: String,
        importedFileId: UUID,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.description = description
        self.amount = amount
        self.categoryId = categoryId
        self.isManuallyCategorized = isManuallyCategorized
        self.month = month
        self.importedFileId = importedFileId
        self.importedAt = importedAt
    }
}

extension Transaction: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transaction"

    enum Columns: String, ColumnExpression {
        case id, date, description, amount, categoryId
        case isManuallyCategorized, month, importedFileId, importedAt
    }
}
