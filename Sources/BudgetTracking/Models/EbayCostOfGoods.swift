import Foundation
import GRDB

struct EbayCostOfGoods: Identifiable, Codable, Equatable {
    var id: UUID
    var ebayOrderId: UUID
    var costAmount: Double
    var shippingCost: Double
    var notes: String?

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        ebayOrderId: UUID,
        costAmount: Double = 0,
        shippingCost: Double = 0,
        notes: String? = nil,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.ebayOrderId = ebayOrderId
        self.costAmount = costAmount
        self.shippingCost = shippingCost
        self.notes = notes
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension EbayCostOfGoods: FetchableRecord, PersistableRecord {
    static let databaseTableName = "ebayCostOfGoods"

    enum Columns: String, ColumnExpression {
        case id, ebayOrderId, costAmount, shippingCost, notes
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
