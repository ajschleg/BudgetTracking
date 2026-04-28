import CloudKit
import Foundation

/// Converts between local GRDB models and CloudKit CKRecords.
enum RecordConverter {

    // MARK: - CKRecord Helpers

    /// Create a CKRecord from archived system fields, or a new one if none exist.
    private static func record(
        type: String, recordName: String, systemFields: Data?
    ) -> CKRecord {
        if let data = systemFields {
            let unarchiver: NSKeyedUnarchiver
            do {
                unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            } catch {
                return CKRecord(
                    recordType: type,
                    recordID: CKRecord.ID(
                        recordName: recordName,
                        zoneID: SyncConstants.zoneID
                    )
                )
            }
            unarchiver.requiresSecureCoding = true
            if let record = CKRecord(coder: unarchiver) {
                unarchiver.finishDecoding()
                return record
            }
            unarchiver.finishDecoding()
        }
        return CKRecord(
            recordType: type,
            recordID: CKRecord.ID(
                recordName: recordName,
                zoneID: SyncConstants.zoneID
            )
        )
    }

    /// Archive the system fields of a CKRecord for storage.
    static func archiveSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    // MARK: - BudgetCategory

    static func ckRecord(from category: BudgetCategory) -> CKRecord {
        let record = record(
            type: SyncConstants.RecordType.budgetCategory,
            recordName: category.cloudKitRecordName ?? category.id.uuidString,
            systemFields: category.cloudKitSystemFields
        )
        record["id"] = category.id.uuidString
        record["name"] = category.name
        record["monthlyBudget"] = category.monthlyBudget
        record["colorHex"] = category.colorHex
        record["sortOrder"] = category.sortOrder
        record["isHiddenFromDashboard"] = category.isHiddenFromDashboard
        record["isIncomeCategory"] = category.isIncomeCategory
        record["isDeleted"] = category.isDeleted
        record["lastModifiedAt"] = category.lastModifiedAt
        return record
    }

    static func budgetCategory(from record: CKRecord) -> BudgetCategory? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = record["name"] as? String
        else { return nil }
        return BudgetCategory(
            id: id,
            name: name,
            monthlyBudget: record["monthlyBudget"] as? Double ?? 0,
            colorHex: record["colorHex"] as? String ?? "#4CAF50",
            sortOrder: record["sortOrder"] as? Int ?? 0,
            isHiddenFromDashboard: record["isHiddenFromDashboard"] as? Bool ?? false,
            isIncomeCategory: record["isIncomeCategory"] as? Bool ?? false,
            lastModifiedAt: record["lastModifiedAt"] as? Date ?? Date(),
            cloudKitRecordName: record.recordID.recordName,
            cloudKitSystemFields: archiveSystemFields(of: record),
            isDeleted: record["isDeleted"] as? Bool ?? false
        )
    }

    // MARK: - Transaction

    static func ckRecord(from transaction: Transaction) -> CKRecord {
        let record = record(
            type: SyncConstants.RecordType.transaction,
            recordName: transaction.cloudKitRecordName ?? transaction.id.uuidString,
            systemFields: transaction.cloudKitSystemFields
        )
        record["id"] = transaction.id.uuidString
        record["date"] = transaction.date
        record["transactionDescription"] = transaction.description
        record["merchant"] = transaction.merchant
        record["amount"] = transaction.amount
        record["categoryId"] = transaction.categoryId?.uuidString
        record["isManuallyCategorized"] = transaction.isManuallyCategorized
        record["month"] = transaction.month
        record["importedFileId"] = transaction.importedFileId.uuidString
        record["importedAt"] = transaction.importedAt
        record["isDeleted"] = transaction.isDeleted
        record["lastModifiedAt"] = transaction.lastModifiedAt
        return record
    }

    static func transaction(from record: CKRecord) -> Transaction? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let date = record["date"] as? Date,
              let amount = record["amount"] as? Double,
              let month = record["month"] as? String,
              let fileIdString = record["importedFileId"] as? String,
              let importedFileId = UUID(uuidString: fileIdString)
        else { return nil }

        let categoryId: UUID?
        if let catString = record["categoryId"] as? String {
            categoryId = UUID(uuidString: catString)
        } else {
            categoryId = nil
        }

        return Transaction(
            id: id,
            date: date,
            description: record["transactionDescription"] as? String ?? "Unknown",
            merchant: record["merchant"] as? String,
            amount: amount,
            categoryId: categoryId,
            isManuallyCategorized: record["isManuallyCategorized"] as? Bool ?? false,
            month: month,
            importedFileId: importedFileId,
            importedAt: record["importedAt"] as? Date ?? Date(),
            lastModifiedAt: record["lastModifiedAt"] as? Date ?? Date(),
            cloudKitRecordName: record.recordID.recordName,
            cloudKitSystemFields: archiveSystemFields(of: record),
            isDeleted: record["isDeleted"] as? Bool ?? false
        )
    }

    // MARK: - ImportedFile

    static func ckRecord(from file: ImportedFile) -> CKRecord {
        let record = record(
            type: SyncConstants.RecordType.importedFile,
            recordName: file.cloudKitRecordName ?? file.id.uuidString,
            systemFields: file.cloudKitSystemFields
        )
        record["id"] = file.id.uuidString
        record["fileName"] = file.fileName
        record["fileSize"] = file.fileSize
        record["month"] = file.month
        record["transactionCount"] = file.transactionCount
        record["importedAt"] = file.importedAt
        record["isDeleted"] = file.isDeleted
        record["lastModifiedAt"] = file.lastModifiedAt
        return record
    }

    static func importedFile(from record: CKRecord) -> ImportedFile? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let fileName = record["fileName"] as? String
        else { return nil }
        return ImportedFile(
            id: id,
            fileName: fileName,
            fileSize: record["fileSize"] as? Int64 ?? 0,
            month: record["month"] as? String,
            transactionCount: record["transactionCount"] as? Int ?? 0,
            importedAt: record["importedAt"] as? Date ?? Date(),
            lastModifiedAt: record["lastModifiedAt"] as? Date ?? Date(),
            cloudKitRecordName: record.recordID.recordName,
            cloudKitSystemFields: archiveSystemFields(of: record),
            isDeleted: record["isDeleted"] as? Bool ?? false
        )
    }

    // MARK: - CategorizationRule

    static func ckRecord(from rule: CategorizationRule) -> CKRecord {
        let record = record(
            type: SyncConstants.RecordType.categorizationRule,
            recordName: rule.cloudKitRecordName ?? rule.id.uuidString,
            systemFields: rule.cloudKitSystemFields
        )
        record["id"] = rule.id.uuidString
        record["keyword"] = rule.keyword
        record["categoryId"] = rule.categoryId.uuidString
        record["priority"] = rule.priority
        record["isUserDefined"] = rule.isUserDefined
        record["matchCount"] = rule.matchCount
        record["isDeleted"] = rule.isDeleted
        record["lastModifiedAt"] = rule.lastModifiedAt
        return record
    }

    static func categorizationRule(from record: CKRecord) -> CategorizationRule? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let keyword = record["keyword"] as? String,
              let catIdString = record["categoryId"] as? String,
              let categoryId = UUID(uuidString: catIdString)
        else { return nil }
        return CategorizationRule(
            id: id,
            keyword: keyword,
            categoryId: categoryId,
            priority: record["priority"] as? Int ?? 0,
            isUserDefined: record["isUserDefined"] as? Bool ?? true,
            matchCount: record["matchCount"] as? Int ?? 0,
            lastModifiedAt: record["lastModifiedAt"] as? Date ?? Date(),
            cloudKitRecordName: record.recordID.recordName,
            cloudKitSystemFields: archiveSystemFields(of: record),
            isDeleted: record["isDeleted"] as? Bool ?? false
        )
    }

    // MARK: - MonthlySnapshot

    static func ckRecord(from snapshot: MonthlySnapshot) -> CKRecord {
        let record = record(
            type: SyncConstants.RecordType.monthlySnapshot,
            recordName: snapshot.cloudKitRecordName ?? snapshot.id.uuidString,
            systemFields: snapshot.cloudKitSystemFields
        )
        record["id"] = snapshot.id.uuidString
        record["month"] = snapshot.month
        record["totalBudget"] = snapshot.totalBudget
        record["totalSpent"] = snapshot.totalSpent
        record["categoryBreakdownData"] = snapshot.categoryBreakdownData
        record["snapshotDate"] = snapshot.snapshotDate
        record["isDeleted"] = snapshot.isDeleted
        record["lastModifiedAt"] = snapshot.lastModifiedAt
        return record
    }

    static func monthlySnapshot(from record: CKRecord) -> MonthlySnapshot? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let month = record["month"] as? String
        else { return nil }
        return MonthlySnapshot(
            id: id,
            month: month,
            totalBudget: record["totalBudget"] as? Double ?? 0,
            totalSpent: record["totalSpent"] as? Double ?? 0,
            categoryBreakdown: {
                if let data = record["categoryBreakdownData"] as? Data,
                   let summaries = try? JSONDecoder().decode([CategorySummary].self, from: data) {
                    return summaries
                }
                return []
            }(),
            snapshotDate: record["snapshotDate"] as? Date ?? Date(),
            lastModifiedAt: record["lastModifiedAt"] as? Date ?? Date(),
            cloudKitRecordName: record.recordID.recordName,
            cloudKitSystemFields: archiveSystemFields(of: record),
            isDeleted: record["isDeleted"] as? Bool ?? false
        )
    }

    // MARK: - BankProfile

    static func ckRecord(from profile: BankProfile) -> CKRecord {
        let record = record(
            type: SyncConstants.RecordType.bankProfile,
            recordName: profile.cloudKitRecordName ?? profile.id.uuidString,
            systemFields: profile.cloudKitSystemFields
        )
        record["id"] = profile.id.uuidString
        record["name"] = profile.name
        record["fileType"] = profile.fileType
        record["dateColumn"] = profile.dateColumn
        record["descriptionColumn"] = profile.descriptionColumn
        record["amountColumn"] = profile.amountColumn
        record["debitColumn"] = profile.debitColumn
        record["creditColumn"] = profile.creditColumn
        record["dateFormat"] = profile.dateFormat
        record["headerRowIndex"] = profile.headerRowIndex
        record["amountSignConvention"] = profile.amountSignConvention.rawValue
        record["isDeleted"] = profile.isDeleted
        record["lastModifiedAt"] = profile.lastModifiedAt
        return record
    }

    static func bankProfile(from record: CKRecord) -> BankProfile? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = record["name"] as? String
        else { return nil }
        return BankProfile(
            id: id,
            name: name,
            fileType: record["fileType"] as? String ?? "csv",
            dateColumn: record["dateColumn"] as? String,
            descriptionColumn: record["descriptionColumn"] as? String,
            amountColumn: record["amountColumn"] as? String,
            debitColumn: record["debitColumn"] as? String,
            creditColumn: record["creditColumn"] as? String,
            dateFormat: record["dateFormat"] as? String ?? "MM/dd/yyyy",
            headerRowIndex: record["headerRowIndex"] as? Int ?? 0,
            amountSignConvention: BankProfile.AmountSignConvention(
                rawValue: record["amountSignConvention"] as? String ?? "negativeIsDebit"
            ) ?? .negativeIsDebit,
            lastModifiedAt: record["lastModifiedAt"] as? Date ?? Date(),
            cloudKitRecordName: record.recordID.recordName,
            cloudKitSystemFields: archiveSystemFields(of: record),
            isDeleted: record["isDeleted"] as? Bool ?? false
        )
    }

    // MARK: - PlaidAccount

    /// Encode the account metadata that flows to peer devices: institution
    /// name, account name, type, mask, balance fields. Plaid Identity PII
    /// (owner name / email / phone) is intentionally NOT written to the
    /// CKRecord — callers must hand in a `sanitizedForSync()` copy, but
    /// even if they don't, this encoder drops those fields.
    static func ckRecord(from account: PlaidAccount) -> CKRecord {
        let record = record(
            type: SyncConstants.RecordType.plaidAccount,
            recordName: account.cloudKitRecordName ?? account.id.uuidString,
            systemFields: account.cloudKitSystemFields
        )
        record["id"] = account.id.uuidString
        record["plaidAccountId"] = account.plaidAccountId
        record["plaidItemId"] = account.plaidItemId
        record["institutionName"] = account.institutionName
        record["name"] = account.name
        record["officialName"] = account.officialName
        record["type"] = account.type
        record["subtype"] = account.subtype
        record["mask"] = account.mask
        record["balanceCurrent"] = account.balanceCurrent
        record["balanceAvailable"] = account.balanceAvailable
        record["balanceLimit"] = account.balanceLimit
        record["balanceCurrencyCode"] = account.balanceCurrencyCode
        record["balanceFetchedAt"] = account.balanceFetchedAt
        record["isDeleted"] = account.isDeleted
        record["lastModifiedAt"] = account.lastModifiedAt
        return record
    }

    static func plaidAccount(from record: CKRecord) -> PlaidAccount? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let plaidAccountId = record["plaidAccountId"] as? String,
              let plaidItemId = record["plaidItemId"] as? String
        else { return nil }
        return PlaidAccount(
            id: id,
            plaidAccountId: plaidAccountId,
            plaidItemId: plaidItemId,
            institutionName: record["institutionName"] as? String,
            name: record["name"] as? String,
            officialName: record["officialName"] as? String,
            type: record["type"] as? String,
            subtype: record["subtype"] as? String,
            mask: record["mask"] as? String,
            balanceCurrent: record["balanceCurrent"] as? Double,
            balanceAvailable: record["balanceAvailable"] as? Double,
            balanceLimit: record["balanceLimit"] as? Double,
            balanceCurrencyCode: record["balanceCurrencyCode"] as? String,
            balanceFetchedAt: record["balanceFetchedAt"] as? Date,
            // Identity PII intentionally not read from the CKRecord —
            // even if a misbehaving peer wrote it, this side ignores it.
            ownerName: nil,
            ownerEmail: nil,
            ownerPhone: nil,
            identityFetchedAt: nil,
            lastModifiedAt: record["lastModifiedAt"] as? Date ?? Date(),
            cloudKitRecordName: record.recordID.recordName,
            cloudKitSystemFields: archiveSystemFields(of: record),
            isDeleted: record["isDeleted"] as? Bool ?? false
        )
    }
}
