import Foundation
import GRDB

struct EbayFee: Identifiable, Codable, Equatable {
    var id: UUID
    var ebayOrderId: UUID
    var feeType: String
    var amount: Double
    var feeMemo: String?

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        ebayOrderId: UUID,
        feeType: String,
        amount: Double,
        feeMemo: String? = nil,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.ebayOrderId = ebayOrderId
        self.feeType = feeType
        self.amount = amount
        self.feeMemo = feeMemo
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension EbayFee: FetchableRecord, PersistableRecord {
    static let databaseTableName = "ebayFee"

    enum Columns: String, ColumnExpression {
        case id, ebayOrderId, feeType, amount, feeMemo
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
