import Foundation

/// On-device analytics engine that generates budget insights from historical transaction data.
final class InsightsEngine {

    // MARK: - Configuration

    /// Minimum amount for a transaction to be considered a "large" recurring expense.
    private let largeExpenseThreshold: Double = 500

    /// Minimum uncategorized spending to trigger an insight.
    private let uncategorizedThreshold: Double = 100

    /// Percentage above budget that triggers a seasonal alert (0.20 = 20%).
    private let seasonalOverageRatio: Double = 0.20

    /// Number of recent months to analyze for budget overrun trends.
    private let trendMonthCount = 6

    /// Minimum months over budget (out of trendMonthCount) to trigger a trend alert.
    private let trendOverrunMinMonths = 3

    // MARK: - Public API

    func generateInsights(forMonth currentMonth: String, dismissedReturnIds: Set<UUID> = []) throws -> [BudgetInsight] {
        var insights: [BudgetInsight] = []

        let categories = try DatabaseManager.shared.fetchCategories()
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        insights.append(contentsOf: try seasonalAlerts(currentMonth: currentMonth, categories: categories, categoryMap: categoryMap))
        insights.append(contentsOf: try recurringAnnualExpenses(currentMonth: currentMonth))
        insights.append(contentsOf: try budgetOverrunTrends(currentMonth: currentMonth, categories: categories, categoryMap: categoryMap))
        insights.append(contentsOf: try unbudgetedSpending(currentMonth: currentMonth))
        insights.append(contentsOf: try returnDetection(currentMonth: currentMonth, categoryMap: categoryMap, dismissedIds: dismissedReturnIds))

        // Sort by severity (alert first)
        insights.sort { $0.severity > $1.severity }

        return insights
    }

    // MARK: - Insight 1: Seasonal Spending Alerts

    private func seasonalAlerts(
        currentMonth: String,
        categories: [BudgetCategory],
        categoryMap: [UUID: BudgetCategory]
    ) throws -> [BudgetInsight] {
        // Find same calendar month in previous years
        let priorSameMonths = sameCalendarMonthInPriorYears(currentMonth: currentMonth)
        guard !priorSameMonths.isEmpty else { return [] }

        let allMonths = try DatabaseManager.shared.fetchAllSnapshotMonths()
        let availableMonths = priorSameMonths.filter { allMonths.contains($0) }
        guard !availableMonths.isEmpty else { return [] }

        let historicalSpending = try DatabaseManager.shared.fetchSpendingByCategory(forMonths: availableMonths)

        var insights: [BudgetInsight] = []

        for category in categories {
            guard category.monthlyBudget > 0 else { continue }

            // Average spending for this category across same-month history
            var totalHistorical: Double = 0
            var monthsWithData = 0
            for month in availableMonths {
                if let spending = historicalSpending[month]?[category.id] {
                    totalHistorical += spending
                    monthsWithData += 1
                }
            }
            guard monthsWithData > 0 else { continue }

            let avgHistorical = totalHistorical / Double(monthsWithData)
            let overageRatio = (avgHistorical - category.monthlyBudget) / category.monthlyBudget

            if overageRatio > seasonalOverageRatio {
                let monthName = extractMonthName(from: currentMonth)
                insights.append(BudgetInsight(
                    type: .seasonalAlert,
                    severity: overageRatio > 0.5 ? .alert : .warning,
                    title: "\(category.name) typically costs more in \(monthName)",
                    description: "In past years, you spent an average of \(CurrencyFormatter.format(avgHistorical)) on \(category.name) in \(monthName), but your budget is \(CurrencyFormatter.format(category.monthlyBudget)).",
                    suggestedAction: "Consider increasing the \(category.name) budget to \(CurrencyFormatter.format(avgHistorical)) for this month.",
                    iconName: "calendar.badge.exclamationmark",
                    relatedCategoryName: category.name,
                    relatedAmount: avgHistorical
                ))
            }
        }

        return insights
    }

    // MARK: - Insight 2: Recurring Annual Expenses

    private func recurringAnnualExpenses(currentMonth: String) throws -> [BudgetInsight] {
        // Look at same month one year ago
        guard let lastYearMonth = sameMonthLastYear(currentMonth) else { return [] }

        let allMonths = try DatabaseManager.shared.fetchAllSnapshotMonths()
        guard allMonths.contains(lastYearMonth) else { return [] }

        let largeTxns = try DatabaseManager.shared.fetchLargeTransactions(
            forMonth: lastYearMonth, threshold: largeExpenseThreshold
        )
        guard !largeTxns.isEmpty else { return [] }

        // Get current month's transactions for comparison
        let currentTxns = try DatabaseManager.shared.fetchTransactions(forMonth: currentMonth)

        var insights: [BudgetInsight] = []

        for txn in largeTxns {
            let amount = abs(txn.amount)
            let desc = txn.description.lowercased()
            let merchant = txn.merchant?.lowercased()

            // Check if a similar transaction exists this month
            let hasMatch = currentTxns.contains { current in
                let currentDesc = current.description.lowercased()
                let currentMerchant = current.merchant?.lowercased()

                // Match by description substring
                if !desc.isEmpty && currentDesc.contains(desc) { return true }
                if !desc.isEmpty && desc.contains(currentDesc) && currentDesc.count > 3 { return true }

                // Match by merchant
                if let m = merchant, let cm = currentMerchant, m == cm { return true }

                // Match by same category with similar amount (within 30%)
                if let catId = txn.categoryId, catId == current.categoryId {
                    let ratio = abs(current.amount) / amount
                    if ratio > 0.7 && ratio < 1.3 { return true }
                }

                return false
            }

            if !hasMatch {
                let label = txn.merchant ?? txn.description
                let lastYearDisplay = DateHelpers.displayMonth(lastYearMonth)
                insights.append(BudgetInsight(
                    type: .recurringAnnualExpense,
                    severity: .alert,
                    title: "Possible missing expense: \(label)",
                    description: "You paid \(CurrencyFormatter.format(amount)) for \"\(label)\" in \(lastYearDisplay). No similar transaction found this month.",
                    suggestedAction: "Check if this expense is upcoming and add it to your budget.",
                    iconName: "exclamationmark.triangle.fill",
                    relatedCategoryName: nil,
                    relatedAmount: amount
                ))
            }
        }

        return insights
    }

    // MARK: - Insight 3: Budget-vs-Actual Trends

    private func budgetOverrunTrends(
        currentMonth: String,
        categories: [BudgetCategory],
        categoryMap: [UUID: BudgetCategory]
    ) throws -> [BudgetInsight] {
        // Get the last N months
        let recentMonths = previousMonths(from: currentMonth, count: trendMonthCount)
        let allMonths = try DatabaseManager.shared.fetchAllSnapshotMonths()
        let availableMonths = recentMonths.filter { allMonths.contains($0) }
        guard availableMonths.count >= 3 else { return [] } // Need at least 3 months of data

        var insights: [BudgetInsight] = []

        for category in categories {
            guard category.monthlyBudget > 0 else { continue }

            let spending = try DatabaseManager.shared.fetchSpendingByMonth(
                forCategory: category.id, months: availableMonths
            )

            var overBudgetCount = 0
            var totalOverage: Double = 0

            for month in availableMonths {
                let spent = spending[month] ?? 0
                if spent > category.monthlyBudget {
                    overBudgetCount += 1
                    totalOverage += spent - category.monthlyBudget
                }
            }

            if overBudgetCount >= trendOverrunMinMonths {
                let avgOverage = totalOverage / Double(overBudgetCount)
                insights.append(BudgetInsight(
                    type: .budgetOverrun,
                    severity: .warning,
                    title: "\(category.name) consistently over budget",
                    description: "\(category.name) has exceeded its \(CurrencyFormatter.format(category.monthlyBudget)) budget in \(overBudgetCount) of the last \(availableMonths.count) months, by an average of \(CurrencyFormatter.format(avgOverage)).",
                    suggestedAction: "Consider increasing the budget to \(CurrencyFormatter.format(category.monthlyBudget + avgOverage)).",
                    iconName: "chart.line.uptrend.xyaxis",
                    relatedCategoryName: category.name,
                    relatedAmount: avgOverage
                ))
            }
        }

        return insights
    }

    // MARK: - Insight 4: Unbudgeted Spending

    private func unbudgetedSpending(currentMonth: String) throws -> [BudgetInsight] {
        let uncategorized = try DatabaseManager.shared.fetchUncategorizedSpending(forMonth: currentMonth)
        guard uncategorized > uncategorizedThreshold else { return [] }

        return [
            BudgetInsight(
                type: .unbudgetedSpending,
                severity: .info,
                title: "Significant uncategorized spending",
                description: "You have \(CurrencyFormatter.format(uncategorized)) in uncategorized transactions this month.",
                suggestedAction: "Review uncategorized transactions and assign them to categories, or create new categories.",
                iconName: "questionmark.folder.fill",
                relatedCategoryName: nil,
                relatedAmount: uncategorized
            )
        ]
    }

    // MARK: - Date Helpers

    /// Returns "yyyy-MM" strings for the same calendar month in prior years.
    private func sameCalendarMonthInPriorYears(currentMonth: String) -> [String] {
        guard let date = DateHelpers.parseDate(currentMonth + "-01", format: "yyyy-MM-dd") else { return [] }
        let cal = Calendar.current
        var results: [String] = []
        for yearsBack in 1...5 {
            if let priorDate = cal.date(byAdding: .year, value: -yearsBack, to: date) {
                results.append(DateHelpers.monthString(from: priorDate))
            }
        }
        return results
    }

    /// Returns the same month one year ago, or nil.
    private func sameMonthLastYear(_ currentMonth: String) -> String? {
        sameCalendarMonthInPriorYears(currentMonth: currentMonth).first
    }

    /// Returns the previous N months (not including currentMonth).
    private func previousMonths(from currentMonth: String, count: Int) -> [String] {
        var months: [String] = []
        var month = currentMonth
        for _ in 0..<count {
            month = DateHelpers.previousMonth(from: month)
            months.append(month)
        }
        return months
    }

    // MARK: - Insight 5: Return Detection

    /// Keywords in transaction descriptions that strongly indicate a return/refund.
    private static let returnKeywords = ["return", "credit", "refund", "reversal", "chargeback"]

    /// Patterns that indicate income, NOT a return (even if positive and categorized).
    private static let incomePatterns = [
        "ach deposit", "direct deposit", "payroll", "salary", "wage",
        "zelle", "venmo", "cashapp", "cash app", "transfer from",
        "interest", "dividend", "irs", "tax refund"
    ]

    /// Check if a transaction description looks like income rather than a return.
    private func looksLikeIncome(_ description: String) -> Bool {
        let lower = description.lowercased()
        return Self.incomePatterns.contains { lower.contains($0) }
    }

    /// Check if a transaction description contains return/refund keywords.
    private func hasReturnKeyword(_ description: String) -> Bool {
        let lower = description.lowercased()
        return Self.returnKeywords.contains { lower.contains($0) }
    }

    private func returnDetection(
        currentMonth: String,
        categoryMap: [UUID: BudgetCategory],
        dismissedIds: Set<UUID>
    ) throws -> [BudgetInsight] {
        let transactions = try DatabaseManager.shared.fetchTransactions(forMonth: currentMonth)

        // Find positive-amount categorized transactions (potential returns)
        let candidates = transactions.filter { txn in
            txn.amount > 0
            && txn.categoryId != nil
            && !dismissedIds.contains(txn.id)
            && !looksLikeIncome(txn.description)  // Skip obvious income
        }

        guard !candidates.isEmpty else { return [] }

        // Get all negative transactions for merchant matching
        let purchases = transactions.filter { $0.amount < 0 }

        var insights: [BudgetInsight] = []

        for ret in candidates {
            let desc = ret.description
            let isReturnLabeled = hasReturnKeyword(desc)

            // Clean the description for merchant matching
            let cleanedDesc = desc.replacingOccurrences(
                of: #"\s*\((?:RETURN|CREDIT|REFUND|REVERSAL)\)\s*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).lowercased()

            // Match against purchases: same category + similar description
            let matchingPurchases = purchases.filter { purchase in
                // Must be in the same category
                guard purchase.categoryId == ret.categoryId else { return false }
                let purchaseDesc = purchase.description.lowercased()
                // Match if descriptions share a significant common prefix (≥15 chars)
                let prefixLen = min(15, min(cleanedDesc.count, purchaseDesc.count))
                guard prefixLen >= 8 else { return false }
                return purchaseDesc.hasPrefix(String(cleanedDesc.prefix(prefixLen)))
                    || cleanedDesc.hasPrefix(String(purchaseDesc.prefix(prefixLen)))
            }

            // Only flag as a return if:
            // 1. Description contains return/refund keywords, OR
            // 2. There's a matching purchase in the same category
            let isLikelyReturn = isReturnLabeled || !matchingPurchases.isEmpty

            guard isLikelyReturn else { continue }

            let categoryName = ret.categoryId.flatMap { categoryMap[$0]?.name } ?? "Uncategorized"
            let amount = ret.amount

            var description: String
            if !matchingPurchases.isEmpty {
                let purchaseTotal = matchingPurchases.reduce(0.0) { $0 + abs($1.amount) }
                description = "Detected a \(CurrencyFormatter.format(amount)) return"
                if isReturnLabeled { description += " (labeled as return)" }
                description += " in \(categoryName). Found \(matchingPurchases.count) related purchase(s) totaling \(CurrencyFormatter.format(purchaseTotal)). Net impact: \(CurrencyFormatter.format(purchaseTotal - amount))."
            } else {
                description = "Detected a \(CurrencyFormatter.format(amount)) return"
                if isReturnLabeled { description += " (labeled as return)" }
                description += " in \(categoryName). This offsets \(categoryName) spending."
            }

            insights.append(BudgetInsight(
                type: .returnDetected,
                severity: .info,
                title: "Return: \(desc.prefix(40))\(desc.count > 40 ? "…" : "")",
                description: description,
                suggestedAction: "If this is not a return, tap \"Not a Return\" to exclude it from spending offsets.",
                iconName: "arrow.uturn.left.circle.fill",
                relatedCategoryName: categoryName,
                relatedAmount: amount,
                relatedTransactionId: ret.id
            ))
        }

        return insights
    }

    /// Extracts a human-readable month name (e.g., "March") from "2026-03".
    private func extractMonthName(from monthString: String) -> String {
        guard let date = DateHelpers.parseDate(monthString + "-01", format: "yyyy-MM-dd") else {
            return monthString
        }
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: date)
    }
}
