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

    /// Pure split of all categories into the dashboard-visible subset, the
    /// set of hidden ids (used to exclude transactions from totals), and the
    /// sum of visible budgets. Extracted so the invariant
    /// `totalBudget == sum(visible.monthlyBudget)` can be unit-tested without
    /// a live database.
    struct CategorySplit: Equatable {
        let visible: [BudgetCategory]
        let hiddenIds: Set<UUID>
        let totalBudget: Double
    }

    static func splitForDashboard(_ all: [BudgetCategory]) -> CategorySplit {
        let hiddenIds = Set(all.filter { $0.isHiddenFromDashboard }.map { $0.id })
        let visible = all.filter { !$0.isHiddenFromDashboard }
        let totalBudget = visible.reduce(0) { $0 + $1.monthlyBudget }
        return CategorySplit(visible: visible, hiddenIds: hiddenIds, totalBudget: totalBudget)
    }

    /// Pure mirror of the dashboard's "Income" computation. The dashboard
    /// section sums every positive, non-deleted transaction in the given
    /// month — regardless of category. Hidden categories are intentionally
    /// NOT filtered here: paychecks tagged to a hidden "Income" category
    /// or sales tagged to a hidden side-hustle category are still real
    /// income. Mirrors the SQL in `DatabaseManager.fetchTotalIncome` /
    /// `fetchIncomeTransactions`. Used by unit tests to lock the rule down.
    struct IncomeSnapshot: Equatable {
        let total: Double
        let transactions: [Transaction]
    }

    static func incomeSnapshot(from transactions: [Transaction], forMonth month: String) -> IncomeSnapshot {
        let included = transactions
            .filter { $0.month == month && $0.amount > 0 && !$0.isDeleted }
            .sorted { $0.date > $1.date }
        let total = included.reduce(0) { $0 + $1.amount }
        return IncomeSnapshot(total: total, transactions: included)
    }

    func load(month: String) {
        currentMonth = month
        do {
            let split = Self.splitForDashboard(try DatabaseManager.shared.fetchCategories())
            categories = split.visible
            totalBudget = split.totalBudget
            spendingByCategory = try DatabaseManager.shared.fetchSpendingByCategory(forMonth: month)
            totalSpent = try DatabaseManager.shared.fetchTotalSpending(forMonth: month, excludeCategoryIds: split.hiddenIds)
            // Income is intentionally NOT filtered by hidden categories: a
            // user typically hides the "Income" / "Money Transfers" / etc.
            // categories so they don't pollute the budget bars, but their
            // positive transactions are still real income (paychecks, refunds,
            // side-hustle sales). The IncomeBreakdownSheet lets the user
            // exclude individual transactions if any of them are noise.
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
