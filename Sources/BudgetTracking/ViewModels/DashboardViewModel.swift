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
    /// set of hidden ids (used to exclude transactions from totals), the
    /// set of income-category ids (used to scope income), and the sum of
    /// visible budgets. Extracted so the invariants can be unit-tested
    /// without a live database.
    struct CategorySplit: Equatable {
        let visible: [BudgetCategory]
        let hiddenIds: Set<UUID>
        let incomeCategoryIds: Set<UUID>
        let totalBudget: Double
    }

    static func splitForDashboard(_ all: [BudgetCategory]) -> CategorySplit {
        let hiddenIds = Set(all.filter { $0.isHiddenFromDashboard }.map { $0.id })
        let incomeCategoryIds = Set(all.filter { $0.isIncomeCategory }.map { $0.id })
        let visible = all.filter { !$0.isHiddenFromDashboard }
        let totalBudget = visible.reduce(0) { $0 + $1.monthlyBudget }
        return CategorySplit(
            visible: visible,
            hiddenIds: hiddenIds,
            incomeCategoryIds: incomeCategoryIds,
            totalBudget: totalBudget
        )
    }

    /// Pure mirror of the dashboard's "Income" computation. Sums every
    /// positive, non-deleted transaction in the given month whose
    /// `categoryId` is in `incomeCategoryIds`. A transaction with a NULL
    /// category, or one tagged to a category the user has not marked as
    /// income, is treated as a refund/transfer/Zelle-payment and excluded.
    /// Mirrors the SQL in `DatabaseManager.fetchTotalIncome` /
    /// `fetchIncomeTransactions` when called with `fromCategoryIds`.
    struct IncomeSnapshot: Equatable {
        let total: Double
        let transactions: [Transaction]
    }

    static func incomeSnapshot(
        from transactions: [Transaction],
        forMonth month: String,
        incomeCategoryIds: Set<UUID>
    ) -> IncomeSnapshot {
        let included = transactions
            .filter {
                $0.month == month
                && $0.amount > 0
                && !$0.isDeleted
                && $0.categoryId.map { incomeCategoryIds.contains($0) } == true
            }
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
            // Income is scoped to the categories the user has explicitly
            // marked as income sources (the $ toggle in Categories
            // settings). Refunds, transfers, and Zelle reimbursements
            // therefore don't pollute the dashboard total.
            totalIncome = try DatabaseManager.shared.fetchTotalIncome(forMonth: month, fromCategoryIds: split.incomeCategoryIds)
            incomeTransactions = try DatabaseManager.shared.fetchIncomeTransactions(forMonth: month, fromCategoryIds: split.incomeCategoryIds)
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
