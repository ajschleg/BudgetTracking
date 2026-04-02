import Foundation
import GRDB

struct EbayPayout: Identifiable, Codable, Equatable {
    var id: UUID
    var ebayPayoutId: String
    var payoutDate: Date
    var amount: Double
    var status: String
    var month: String
    var matchedTransactionId: UUID?

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        ebayPayoutId: String,
        payoutDate: Date,
        amount: Double,
        status: String,
        month: String,
        matchedTransactionId: UUID? = nil,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.ebayPayoutId = ebayPayoutId
        self.payoutDate = payoutDate
        self.amount = amount
        self.status = status
        self.month = month
        self.matchedTransactionId = matchedTransactionId
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension EbayPayout: FetchableRecord, PersistableRecord {
    static let databaseTableName = "ebayPayout"

    enum Columns: String, ColumnExpression {
        case id, ebayPayoutId, payoutDate, amount, status, month, matchedTransactionId
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
