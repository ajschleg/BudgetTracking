import Foundation
import GRDB

struct ImportedFile: Identifiable, Codable, Equatable {
    var id: UUID
    var fileName: String
    var fileSize: Int64
    var month: String? // "2026-03" for single-month files, nil for multi-month
    var transactionCount: Int
    var importedAt: Date

    /// True when the file contains transactions spanning multiple months.
    var isMultiMonth: Bool { month == nil }

    init(
        id: UUID = UUID(),
        fileName: String,
        fileSize: Int64,
        month: String? = nil,
        transactionCount: Int = 0,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.month = month
        self.transactionCount = transactionCount
        self.importedAt = importedAt
    }
}

extension ImportedFile: FetchableRecord, PersistableRecord {
    static let databaseTableName = "importedFile"

    enum Columns: String, ColumnExpression {
        case id, fileName, fileSize, month, transactionCount, importedAt
    }
}
