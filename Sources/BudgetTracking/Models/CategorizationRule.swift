import Foundation
import GRDB

struct CategorizationRule: Identifiable, Codable, Equatable {
    var id: UUID
    var keyword: String
    var categoryId: UUID
    var priority: Int
    var isUserDefined: Bool
    var matchCount: Int

    init(
        id: UUID = UUID(),
        keyword: String,
        categoryId: UUID,
        priority: Int = 0,
        isUserDefined: Bool = true,
        matchCount: Int = 0
    ) {
        self.id = id
        self.keyword = keyword
        self.categoryId = categoryId
        self.priority = priority
        self.isUserDefined = isUserDefined
        self.matchCount = matchCount
    }
}

extension CategorizationRule: FetchableRecord, PersistableRecord {
    static let databaseTableName = "categorizationRule"

    enum Columns: String, ColumnExpression {
        case id, keyword, categoryId, priority, isUserDefined, matchCount
    }
}
