import Foundation
import SwiftUI

@Observable
final class DashboardViewModel {
    var categories: [BudgetCategory] = []
    var spendingByCategory: [UUID: Double] = [:]
    var totalSpent: Double = 0
    var totalBudget: Double = 0
    var totalIncome: Double = 0
    var incomeTransactions: [Transaction] = []
    var isIncomeExpanded = false
    var errorMessage: String?

    /// The currently expanded category (nil = none expanded).
    var expandedCategoryId: UUID?

    /// Transactions for the currently expanded category.
    var expandedTransactions: [Transaction] = []

    private var currentMonth: String = ""

    func load(month: String) {
        currentMonth = month
        do {
            categories = try DatabaseManager.shared.fetchCategories()
            spendingByCategory = try DatabaseManager.shared.fetchSpendingByCategory(forMonth: month)
            totalSpent = try DatabaseManager.shared.fetchTotalSpending(forMonth: month)
            totalBudget = categories.reduce(0) { $0 + $1.monthlyBudget }
            totalIncome = try DatabaseManager.shared.fetchTotalIncome(forMonth: month)
            incomeTransactions = try DatabaseManager.shared.fetchIncomeTransactions(forMonth: month)
            errorMessage = nil

            // Refresh expanded transactions if a category is still expanded
            if let expandedId = expandedCategoryId {
                expandedTransactions = try DatabaseManager.shared.fetchTransactions(
                    forMonth: month, categoryId: expandedId
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleCategory(_ categoryId: UUID) {
        if expandedCategoryId == categoryId {
            expandedCategoryId = nil
            expandedTransactions = []
        } else {
            expandedCategoryId = categoryId
            do {
                expandedTransactions = try DatabaseManager.shared.fetchTransactions(
                    forMonth: currentMonth, categoryId: categoryId
                )
            } catch {
                expandedTransactions = []
            }
        }
    }

    func changeTransactionCategory(_ transactionId: UUID, to newCategoryId: UUID) {
        do {
            try DatabaseManager.shared.updateTransactionCategory(transactionId, categoryId: newCategoryId, isManual: true)
            // Refresh spending data
            load(month: currentMonth)
            // Re-expand the current category to update the transaction list
            if let expanded = expandedCategoryId {
                expandedTransactions = try DatabaseManager.shared.fetchTransactions(
                    forMonth: currentMonth, categoryId: expanded
                )
            }
        } catch {
            // Silently fail — the picker will revert on next load
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
