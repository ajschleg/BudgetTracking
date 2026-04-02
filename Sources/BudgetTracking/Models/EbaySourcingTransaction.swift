import Foundation
import GRDB

/// Links a budget transaction to the eBay sourcing cost pool.
/// Transactions linked here are counted as sourcing costs in the eBay earnings calculation.
struct EbaySourcingTransaction: Identifiable, Codable, Equatable {
    var id: UUID
    var transactionId: UUID
    var month: String

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        transactionId: UUID,
        month: String,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.transactionId = transactionId
        self.month = month
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension EbaySourcingTransaction: FetchableRecord, PersistableRecord {
    static let databaseTableName = "ebaySourcingTransaction"

    enum Columns: String, ColumnExpression {
        case id, transactionId, month
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
