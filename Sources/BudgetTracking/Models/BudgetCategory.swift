import Foundation
import GRDB

struct BudgetCategory: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var monthlyBudget: Double
    var colorHex: String
    var sortOrder: Int
    var isHiddenFromDashboard: Bool
    /// If true, positive transactions tagged to this category count toward
    /// the dashboard "Income" total. Categories without this flag are not
    /// summed as income even if they have positive transactions (refunds,
    /// transfers, Zelle reimbursements, etc.).
    var isIncomeCategory: Bool

    // Sync fields
    var lastModifiedAt: Date
    var cloudKitRecordName: String?
    var cloudKitSystemFields: Data?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        name: String,
        monthlyBudget: Double,
        colorHex: String = "#4CAF50",
        sortOrder: Int = 0,
        isHiddenFromDashboard: Bool = false,
        isIncomeCategory: Bool = false,
        lastModifiedAt: Date = Date(),
        cloudKitRecordName: String? = nil,
        cloudKitSystemFields: Data? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.monthlyBudget = monthlyBudget
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isHiddenFromDashboard = isHiddenFromDashboard
        self.isIncomeCategory = isIncomeCategory
        self.lastModifiedAt = lastModifiedAt
        self.cloudKitRecordName = cloudKitRecordName
        self.cloudKitSystemFields = cloudKitSystemFields
        self.isDeleted = isDeleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.monthlyBudget = try c.decode(Double.self, forKey: .monthlyBudget)
        self.colorHex = try c.decode(String.self, forKey: .colorHex)
        self.sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        self.isHiddenFromDashboard = try c.decodeIfPresent(Bool.self, forKey: .isHiddenFromDashboard) ?? false
        self.isIncomeCategory = try c.decodeIfPresent(Bool.self, forKey: .isIncomeCategory) ?? false
        self.lastModifiedAt = try c.decode(Date.self, forKey: .lastModifiedAt)
        self.cloudKitRecordName = try c.decodeIfPresent(String.self, forKey: .cloudKitRecordName)
        self.cloudKitSystemFields = try c.decodeIfPresent(Data.self, forKey: .cloudKitSystemFields)
        self.isDeleted = try c.decode(Bool.self, forKey: .isDeleted)
    }

    static func randomColorHex() -> String {
        let colors = ["#4CAF50", "#FF9800", "#2196F3", "#9C27B0", "#E91E63",
                      "#00BCD4", "#795548", "#F44336", "#3F51B5", "#009688",
                      "#FF5722", "#607D8B", "#8BC34A", "#FFC107", "#673AB7"]
        return colors.randomElement() ?? "#4CAF50"
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
        case id, name, monthlyBudget, colorHex, sortOrder, isHiddenFromDashboard, isIncomeCategory
        case lastModifiedAt, cloudKitRecordName, cloudKitSystemFields, isDeleted
    }
}
