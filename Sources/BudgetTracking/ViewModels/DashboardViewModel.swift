import Foundation
import SwiftUI

@Observable
final class DashboardViewModel {
    var categories: [BudgetCategory] = []
    var spendingByCategory: [UUID: Double] = [:]
    var totalSpent: Double = 0
    var totalBudget: Double = 0
    var errorMessage: String?

    func load(month: String) {
        do {
            categories = try DatabaseManager.shared.fetchCategories()
            spendingByCategory = try DatabaseManager.shared.fetchSpendingByCategory(forMonth: month)
            totalSpent = try DatabaseManager.shared.fetchTotalSpending(forMonth: month)
            totalBudget = categories.reduce(0) { $0 + $1.monthlyBudget }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func spending(for category: BudgetCategory) -> Double {
        spendingByCategory[category.id] ?? 0
    }

    func percentage(for category: BudgetCategory) -> Double {
        guard category.monthlyBudget > 0 else { return 0 }
        return spending(for: category) / category.monthlyBudget
    }

    var overallPercentage: Double {
        guard totalBudget > 0 else { return 0 }
        return totalSpent / totalBudget
    }
}
