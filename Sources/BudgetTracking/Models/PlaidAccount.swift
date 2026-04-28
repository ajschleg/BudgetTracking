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

    // Balance fields (populated by Plaid Balance product)
    var balanceCurrent: Double?
    var balanceAvailable: Double?
    var balanceLimit: Double?
    var balanceCurrencyCode: String?
    var balanceFetchedAt: Date?

    // Identity fields (populated by Plaid Identity product)
    var ownerName: String?
    var ownerEmail: String?
    var ownerPhone: String?
    var identityFetchedAt: Date?

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
        balanceCurrent: Double? = nil,
        balanceAvailable: Double? = nil,
        balanceLimit: Double? = nil,
        balanceCurrencyCode: String? = nil,
        balanceFetchedAt: Date? = nil,
        ownerName: String? = nil,
        ownerEmail: String? = nil,
        ownerPhone: String? = nil,
        identityFetchedAt: Date? = nil,
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
        self.balanceCurrent = balanceCurrent
        self.balanceAvailable = balanceAvailable
        self.balanceLimit = balanceLimit
        self.balanceCurrencyCode = balanceCurrencyCode
        self.balanceFetchedAt = balanceFetchedAt
        self.ownerName = ownerName
        self.ownerEmail = ownerEmail
        self.ownerPhone = ownerPhone
        self.identityFetchedAt = identityFetchedAt
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

    /// Returns a copy with Plaid Identity PII (owner name, email, phone)
    /// stripped. Per `SECURITY_POLICY.md` §10, PII beyond what the app
    /// renders to its own owner does not leave this device — when a
    /// PlaidAccount is shipped over CloudKit or LAN sync to a peer
    /// device, the sender calls this so the peer only sees the
    /// non-PII account metadata (institution, name, mask, balances).
    func sanitizedForSync() -> PlaidAccount {
        var copy = self
        copy.ownerName = nil
        copy.ownerEmail = nil
        copy.ownerPhone = nil
        copy.identityFetchedAt = nil
        return copy
    }
}

extension PlaidAccount: FetchableRecord, PersistableRecord {
    static let databaseTableName = "plaidAccount"

    enum Columns: String, ColumnExpression {
        case id, plaidAccountId, plaidItemId, institutionName
        case name, officialName, type, subtype, mask
        case balanceCurrent, balanceAvailable, balanceLimit
        case balanceCurrencyCode, balanceFetchedAt
        case ownerName, ownerEmail, ownerPhone, identityFetchedAt
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
