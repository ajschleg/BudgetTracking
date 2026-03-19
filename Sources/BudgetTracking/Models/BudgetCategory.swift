import Foundation
import GRDB

struct BudgetCategory: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var monthlyBudget: Double
    var colorHex: String
    var sortOrder: Int
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        monthlyBudget: Double,
        colorHex: String = "#4CAF50",
        sortOrder: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.monthlyBudget = monthlyBudget
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }

    static let defaultCategories: [BudgetCategory] = [
        BudgetCategory(name: "Groceries", monthlyBudget: 600, colorHex: "#4CAF50", sortOrder: 0),
        BudgetCategory(name: "Dining Out", monthlyBudget: 200, colorHex: "#FF9800", sortOrder: 1),
        BudgetCategory(name: "Gas", monthlyBudget: 150, colorHex: "#2196F3", sortOrder: 2),
        BudgetCategory(name: "Utilities", monthlyBudget: 300, colorHex: "#9C27B0", sortOrder: 3),
        BudgetCategory(name: "Entertainment", monthlyBudget: 150, colorHex: "#E91E63", sortOrder: 4),
        BudgetCategory(name: "Shopping", monthlyBudget: 200, colorHex: "#00BCD4", sortOrder: 5),
        BudgetCategory(name: "Transportation", monthlyBudget: 100, colorHex: "#795548", sortOrder: 6),
        BudgetCategory(name: "Health", monthlyBudget: 100, colorHex: "#F44336", sortOrder: 7),
        BudgetCategory(name: "Uncategorized", monthlyBudget: 0, colorHex: "#9E9E9E", sortOrder: 99),
    ]
}

extension BudgetCategory: FetchableRecord, PersistableRecord {
    static let databaseTableName = "budgetCategory"

    enum Columns: String, ColumnExpression {
        case id, name, monthlyBudget, colorHex, sortOrder, isArchived
    }
}
