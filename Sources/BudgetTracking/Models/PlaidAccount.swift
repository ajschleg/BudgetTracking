import Foundation
import GRDB

struct PlaidAccount: Identifiable, Codable, Equatable {
    var id: UUID
    var plaidAccountId: String
    var plaidItemId: String
    var institutionName: String?
    var name: String?
    var officialName: String?
    var type: String? // depository, credit, loan, investment
    var subtype: String? // checking, savings, credit card
    var mask: String? // Last 4 digits

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        plaidAccountId: String,
        plaidItemId: String,
        institutionName: String? = nil,
        name: String? = nil,
        officialName: String? = nil,
        type: String? = nil,
        subtype: String? = nil,
        mask: String? = nil,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.plaidAccountId = plaidAccountId
        self.plaidItemId = plaidItemId
        self.institutionName = institutionName
        self.name = name
        self.officialName = officialName
        self.type = type
        self.subtype = subtype
        self.mask = mask
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }

    var displayName: String {
        let accountName = officialName ?? name ?? "Account"
        if let mask {
            return "\(accountName) ···\(mask)"
        }
        return accountName
    }
}

extension PlaidAccount: FetchableRecord, PersistableRecord {
    static let databaseTableName = "plaidAccount"

    enum Columns: String, ColumnExpression {
        case id, plaidAccountId, plaidItemId, institutionName
        case name, officialName, type, subtype, mask
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
