import Foundation

enum InsightType: String, Codable {
    case seasonalAlert
    case recurringAnnualExpense
    case budgetOverrun
    case unbudgetedSpending
}

enum InsightSeverity: Comparable {
    case info
    case warning
    case alert
}

struct BudgetInsight: Identifiable {
    let id = UUID()
    let type: InsightType
    let severity: InsightSeverity
    let title: String
    let description: String
    let suggestedAction: String?
    let iconName: String
    let relatedCategoryName: String?
    let relatedAmount: Double?
}
