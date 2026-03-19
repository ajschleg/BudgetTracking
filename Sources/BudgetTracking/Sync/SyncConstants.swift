import CloudKit

enum SyncConstants {
    static let containerIdentifier = "iCloud.com.schlegel.BudgetTracking"
    static let zoneName = "BudgetZone"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    // CloudKit record type names (must match the CK Dashboard schema)
    enum RecordType {
        static let budgetCategory = "BudgetCategory"
        static let transaction = "Transaction"
        static let importedFile = "ImportedFile"
        static let categorizationRule = "CategorizationRule"
        static let monthlySnapshot = "MonthlySnapshot"
        static let bankProfile = "BankProfile"
    }
}
