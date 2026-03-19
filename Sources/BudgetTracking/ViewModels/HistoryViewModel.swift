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
            let categories = try DatabaseManager.shared.fetchCategories()
            let totalBudget = categories.reduce(0) { $0 + $1.monthlyBudget }

            months = try allMonths.map { month in
                let spent = try DatabaseManager.shared.fetchTotalSpending(forMonth: month)
                let files = try DatabaseManager.shared.fetchImportedFiles(forMonth: month)
                return MonthSummary(
                    month: month,
                    totalBudget: totalBudget,
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
