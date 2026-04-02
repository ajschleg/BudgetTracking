import Foundation
import GRDB

struct EbayOrder: Identifiable, Codable, Equatable {
    var id: UUID
    var ebayOrderId: String
    var transactionId: String
    var buyerUsername: String?
    var itemTitle: String
    var itemId: String?
    var quantity: Int
    var saleDate: Date
    var saleAmount: Double
    var month: String

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        ebayOrderId: String,
        transactionId: String,
        buyerUsername: String? = nil,
        itemTitle: String,
        itemId: String? = nil,
        quantity: Int = 1,
        saleDate: Date,
        saleAmount: Double,
        month: String,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.ebayOrderId = ebayOrderId
        self.transactionId = transactionId
        self.buyerUsername = buyerUsername
        self.itemTitle = itemTitle
        self.itemId = itemId
        self.quantity = quantity
        self.saleDate = saleDate
        self.saleAmount = saleAmount
        self.month = month
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension EbayOrder: FetchableRecord, PersistableRecord {
    static let databaseTableName = "ebayOrder"

    enum Columns: String, ColumnExpression {
        case id, ebayOrderId, transactionId, buyerUsername, itemTitle, itemId
        case quantity, saleDate, saleAmount, month
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
