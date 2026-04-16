import Foundation
import GRDB

struct Transaction: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var description: String
    var merchant: String?
    var amount: Double
    var categoryId: UUID?
    var isManuallyCategorized: Bool
    var month: String // "2026-03"
    var importedFileId: UUID
    var importedAt: Date
    var externalId: String? // Plaid transaction_id for deduplication

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        date: Date,
        description: String,
        merchant: String? = nil,
        amount: Double,
        categoryId: UUID? = nil,
        isManuallyCategorized: Bool = false,
        month: String,
        importedFileId: UUID,
        importedAt: Date = Date(),
        externalId: String? = nil,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.date = date
        self.description = description
        self.merchant = merchant
        self.amount = amount
        self.categoryId = categoryId
        self.isManuallyCategorized = isManuallyCategorized
        self.month = month
        self.importedFileId = importedFileId
        self.importedAt = importedAt
        self.externalId = externalId
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension Transaction: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transaction"

    enum Columns: String, ColumnExpression {
        case id, date, description, merchant, amount, categoryId
        case isManuallyCategorized, month, importedFileId, importedAt, externalId
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
