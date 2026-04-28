import Foundation

struct MonthSummary: Identifiable {
    var id: String { month }
    var month: String
    var totalBudget: Double
    var totalSpent: Double
    var fileCount: Int

    var percentage: Double {
        guard totalBudget > 0 else { return 0 }
        return totalSpent / totalBudget
    }
}

@Observable
final class HistoryViewModel {
    var months: [MonthSummary] = []
    var errorMessage: String?

    func load() {
        do {
            let allMonths = try DatabaseManager.shared.fetchAllSnapshotMonths()
            // Same split the dashboard uses, so the per-month totals here
            // line up exactly with what the dashboard shows when you open
            // any of these months. Spending in hidden categories (Credit
            // Card Payments, Money Transfers, etc.) and their budgets are
            // excluded from both numerator and denominator.
            let split = DashboardViewModel.splitForDashboard(
                try DatabaseManager.shared.fetchCategories()
            )

            months = try allMonths.map { month in
                let spent = try DatabaseManager.shared.fetchTotalSpending(
                    forMonth: month,
                    inCategoryIds: split.visibleIds
                )
                let files = try DatabaseManager.shared.fetchImportedFiles(forMonth: month)
                return MonthSummary(
                    month: month,
                    totalBudget: split.totalBudget,
                    totalSpent: spent,
                    fileCount: files.count
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
