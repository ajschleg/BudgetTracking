import Foundation
import GRDB

struct ImportedFile: Identifiable, Codable, Equatable {
    var id: UUID
    var fileName: String
    var fileSize: Int64
    var month: String? // "2026-03" for single-month files, nil for multi-month
    var transactionCount: Int
    var importedAt: Date

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    /// True when the file contains transactions spanning multiple months.
    var isMultiMonth: Bool { month == nil }

    init(
        id: UUID = UUID(),
        fileName: String,
        fileSize: Int64,
        month: String? = nil,
        transactionCount: Int = 0,
        importedAt: Date = Date(),
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.month = month
        self.transactionCount = transactionCount
        self.importedAt = importedAt
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension ImportedFile: FetchableRecord, PersistableRecord {
    static let databaseTableName = "importedFile"

    enum Columns: String, ColumnExpression {
        case id, fileName, fileSize, month, transactionCount, importedAt
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
