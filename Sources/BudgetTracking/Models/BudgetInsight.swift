import Foundation

enum InsightType: String, Codable {
    case seasonalAlert
    case recurringAnnualExpense
    case budgetOverrun
    case unbudgetedSpending
    case returnDetected
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
    let relatedTransactionId: UUID?

    init(
        type: InsightType,
        severity: InsightSeverity,
        title: String,
        description: String,
        suggestedAction: String? = nil,
        iconName: String,
        relatedCategoryName: String? = nil,
        relatedAmount: Double? = nil,
        relatedTransactionId: UUID? = nil
    ) {
        self.type = type
        self.severity = severity
        self.title = title
        self.description = description
        self.suggestedAction = suggestedAction
        self.iconName = iconName
        self.relatedCategoryName = relatedCategoryName
        self.relatedAmount = relatedAmount
        self.relatedTransactionId = relatedTransactionId
    }
}
