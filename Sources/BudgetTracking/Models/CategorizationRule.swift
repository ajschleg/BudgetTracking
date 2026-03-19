import Foundation
import GRDB

struct CategorizationRule: Identifiable, Codable, Equatable {
    var id: UUID
    var keyword: String
    var categoryId: UUID
    var priority: Int
    var isUserDefined: Bool
    var matchCount: Int

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        keyword: String,
        categoryId: UUID,
        priority: Int = 0,
        isUserDefined: Bool = true,
        matchCount: Int = 0,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.keyword = keyword
        self.categoryId = categoryId
        self.priority = priority
        self.isUserDefined = isUserDefined
        self.matchCount = matchCount
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }
}

extension CategorizationRule: FetchableRecord, PersistableRecord {
    static let databaseTableName = "categorizationRule"

    enum Columns: String, ColumnExpression {
        case id, keyword, categoryId, priority, isUserDefined, matchCount
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
