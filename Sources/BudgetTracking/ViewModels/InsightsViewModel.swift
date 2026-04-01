import Foundation
import SwiftUI

/// Per-page chat state for the AI assistant.
struct PageChatState {
    var userQuestion: String = ""
    var aiResponse: String = ""
    var aiActions: [ClaudeAPIService.AIAction] = []
    var suggestions: [ClaudeAPIService.BudgetSuggestion] = []
    var aiErrorMessage: String?
    var isExpanded: Bool = false
}

@Observable
final class InsightsViewModel {
    var insights: [BudgetInsight] = []
    var isLoadingInsights = false
    var errorMessage: String?
    var dismissedReturnIds: Set<UUID> = {
        let data = UserDefaults.standard.data(forKey: "dismissedReturnIds") ?? Data()
        return (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }()

    // Per-page chat history
    var pageChatStates: [SidebarItem: PageChatState] = [:]

    // Page-specific AI state (inherently single-page)
    var ruleSuggestions: [ClaudeAPIService.RuleSuggestion] = []
    var ruleResponse: String = ""
    var categorizationSuggestions: [ClaudeAPIService.CategorizationSuggestion] = []
    var categorizationResponse: String = ""
    // Budget generation state
    var budgetStyle: ClaudeAPIService.BudgetStyle = .balanced
    var monthlyIncome: String = ""
    // Income breakdown state
    var incomeTransactions: [Transaction] = []
    var excludedIncomeIds: Set<UUID> = {
        let data = UserDefaults.standard.data(forKey: "excludedIncomeIds") ?? Data()
        return (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }()
    var showIncomeBreakdown = false
    var budgetAllocations: [ClaudeAPIService.BudgetAllocation] = []
    var budgetGenerationResponse: String = ""
    var isLoadingBudgetGeneration = false
    var showApplyBudgetConfirmation = false

    var isLoadingAI = false
    var isLoadingRules = false
    var isLoadingCategorization = false
    var autoCategorizeRunning = false
    var autoCategorizeProgress: String = ""

    private let engine = InsightsEngine()
    private let aiService = ClaudeAPIService()
    private var currentMonth: String = ""

    /// Monthly spending cap in dollars.
    var monthlyCap: Double = UserDefaults.standard.double(forKey: "claudeMonthlyCapUSD").nonZero ?? 1.0 {
        didSet { UserDefaults.standard.set(monthlyCap, forKey: "claudeMonthlyCapUSD") }
    }

    var apiKey: String = UserDefaults.standard.string(forKey: "claudeAPIKey") ?? "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "claudeAPIKey") }
    }

    var isAPIKeyConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Estimated cost spent this calendar month.
    var monthlySpend: Double {
        let (month, spend) = loadUsage()
        let current = currentCalendarMonth()
        return month == current ? spend : 0
    }

    var isOverCap: Bool {
        monthlySpend >= monthlyCap
    }

    func load(month: String) {
        currentMonth = month
        isLoadingInsights = true
        errorMessage = nil

        do {
            insights = try engine.generateInsights(forMonth: month, dismissedReturnIds: dismissedReturnIds)
        } catch {
            errorMessage = error.localizedDescription
            insights = []
        }

        isLoadingInsights = false
    }

    func askAI(page: SidebarItem) async {
        guard isAPIKeyConfigured else {
            pageChatStates[page, default: PageChatState()].aiErrorMessage = "Please enter your Claude API key first."
            return
        }
        guard !isOverCap else {
            pageChatStates[page, default: PageChatState()].aiErrorMessage = "Monthly spending cap of $\(String(format: "%.2f", monthlyCap)) reached. Resets next month."
            return
        }

        let question = pageChatStates[page, default: PageChatState()].userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run {
            isLoadingAI = true
            pageChatStates[page, default: PageChatState()].aiErrorMessage = nil
            pageChatStates[page, default: PageChatState()].aiResponse = ""
            pageChatStates[page, default: PageChatState()].aiActions = []
        }

        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            var summary = try ClaudeAPIService.buildSpendingSummary(
                currentMonth: currentMonth,
                categories: categories
            )
            if !question.isEmpty {
                summary += "\n\n## User Question\n\(question)"
            }
            let result = try await aiService.analyze(apiKey: apiKey, spendingSummary: summary)
            recordUsage(inputTokens: result.inputTokens, outputTokens: result.outputTokens)
            await MainActor.run {
                pageChatStates[page, default: PageChatState()].aiResponse = result.text
                pageChatStates[page, default: PageChatState()].suggestions = result.suggestions
                pageChatStates[page, default: PageChatState()].aiActions = result.actions
                pageChatStates[page, default: PageChatState()].isExpanded = true
                isLoadingAI = false
            }
        } catch {
            await MainActor.run {
                pageChatStates[page, default: PageChatState()].aiErrorMessage = error.localizedDescription
                isLoadingAI = false
            }
        }
    }

    // MARK: - Return Dismissal

    func dismissReturn(_ transactionId: UUID) {
        dismissedReturnIds.insert(transactionId)
        if let data = try? JSONEncoder().encode(dismissedReturnIds) {
            UserDefaults.standard.set(data, forKey: "dismissedReturnIds")
        }
        // Remove the insight card
        insights.removeAll { $0.relatedTransactionId == transactionId }
    }

    // MARK: - Apply Suggestions

    func applySuggestion(_ suggestion: ClaudeAPIService.BudgetSuggestion, page: SidebarItem) {
        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            if var category = categories.first(where: {
                $0.name.lowercased() == suggestion.category.lowercased()
            }) {
                category.monthlyBudget = suggestion.suggestedBudget
                try DatabaseManager.shared.saveCategory(category)
            } else {
                let newCategory = BudgetCategory(
                    name: suggestion.category,
                    monthlyBudget: suggestion.suggestedBudget,
                    colorHex: BudgetCategory.randomColorHex(),
                    sortOrder: categories.count
                )
                try DatabaseManager.shared.saveCategory(newCategory)
            }
            pageChatStates[page, default: PageChatState()].suggestions.removeAll { $0.id == suggestion.id }
        } catch {
            pageChatStates[page, default: PageChatState()].aiErrorMessage = "Failed to apply: \(error.localizedDescription)"
        }
    }

    // MARK: - Apply AI Actions

    func applyAction(_ action: ClaudeAPIService.AIAction, page: SidebarItem) {
        switch action {
        case .budgetChange(let suggestion):
            applySuggestion(suggestion, page: page)
            pageChatStates[page, default: PageChatState()].aiActions.removeAll { $0.id == action.id }
        case .transactionUpdate(let txnAction):
            applyTransactionAction(txnAction, page: page)
            pageChatStates[page, default: PageChatState()].aiActions.removeAll { $0.id == action.id }
        case .ruleCreation(let rule):
            applyRuleFromAction(rule, page: page)
            pageChatStates[page, default: PageChatState()].aiActions.removeAll { $0.id == action.id }
        }
    }

    func applyAllActions(page: SidebarItem) {
        let actions = pageChatStates[page, default: PageChatState()].aiActions
        let sorted = actions.sorted { a, b in
            func priority(_ action: ClaudeAPIService.AIAction) -> Int {
                switch action {
                case .budgetChange: return 0
                case .transactionUpdate: return 1
                case .ruleCreation: return 2
                }
            }
            return priority(a) < priority(b)
        }
        for action in sorted {
            applyAction(action, page: page)
        }
    }

    /// Resolve a category name to its UUID, creating the category if it doesn't exist.
    private func resolveOrCreateCategory(named name: String) throws -> UUID {
        let categories = try DatabaseManager.shared.fetchCategories()
        if let existing = categories.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return existing.id
        }
        // Create it
        let newCategory = BudgetCategory(
            name: name,
            monthlyBudget: 0,
            colorHex: BudgetCategory.randomColorHex(),
            sortOrder: categories.count
        )
        try DatabaseManager.shared.saveCategory(newCategory)
        return newCategory.id
    }

    private func applyTransactionAction(_ action: ClaudeAPIService.TransactionAction, page: SidebarItem) {
        do {
            let categoryName = action.category ?? ""
            let categoryId = try resolveOrCreateCategory(named: categoryName)

            let transactions = try DatabaseManager.shared.fetchTransactions(forMonth: currentMonth)
            let pattern = action.descriptionPattern.lowercased()
            let matching = transactions.filter {
                $0.description.lowercased().contains(pattern)
            }

            for txn in matching {
                try DatabaseManager.shared.updateTransactionCategory(
                    txn.id, categoryId: categoryId, isManual: true
                )
            }
        } catch {
            pageChatStates[page, default: PageChatState()].aiErrorMessage = "Failed to apply: \(error.localizedDescription)"
        }
    }

    private func applyRuleFromAction(_ rule: ClaudeAPIService.RuleSuggestion, page: SidebarItem) {
        do {
            let categoryId = try resolveOrCreateCategory(named: rule.category)

            let newRule = CategorizationRule(
                keyword: rule.keyword,
                categoryId: categoryId,
                priority: 100,
                isUserDefined: true
            )
            try DatabaseManager.shared.saveRule(newRule)
        } catch {
            pageChatStates[page, default: PageChatState()].aiErrorMessage = "Failed to create rule: \(error.localizedDescription)"
        }
    }

    // MARK: - Rule Suggestions

    func suggestRules() async {
        guard isAPIKeyConfigured else {
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Please enter your Claude API key first."
            return
        }
        guard !isOverCap else {
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Monthly spending cap of $\(String(format: "%.2f", monthlyCap)) reached. Resets next month."
            return
        }

        await MainActor.run {
            isLoadingRules = true
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = nil
            ruleResponse = ""
            ruleSuggestions = []
        }

        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            let prompt = try ClaudeAPIService.buildRulePrompt(
                currentMonth: currentMonth,
                categories: categories
            )
            let result = try await aiService.suggestRules(apiKey: apiKey, prompt: prompt)
            recordUsage(inputTokens: result.inputTokens, outputTokens: result.outputTokens)
            await MainActor.run {
                ruleResponse = result.text
                ruleSuggestions = result.rules
                isLoadingRules = false
                pageChatStates[.categories, default: PageChatState()].isExpanded = true
            }
        } catch {
            await MainActor.run {
                pageChatStates[.categories, default: PageChatState()].aiErrorMessage = error.localizedDescription
                isLoadingRules = false
            }
        }
    }

    func applyRule(_ rule: ClaudeAPIService.RuleSuggestion) {
        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            guard let category = categories.first(where: {
                $0.name.lowercased() == rule.category.lowercased()
            }) else {
                pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Category \"\(rule.category)\" not found."
                return
            }
            let existingRules = try DatabaseManager.shared.fetchRules()
            let maxPriority = existingRules.map(\.priority).max() ?? 0
            let newRule = CategorizationRule(
                keyword: rule.keyword,
                categoryId: category.id,
                priority: maxPriority + 1,
                isUserDefined: true
            )
            try DatabaseManager.shared.saveRule(newRule)
            ruleSuggestions.removeAll { $0.id == rule.id }
        } catch {
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Failed to apply rule: \(error.localizedDescription)"
        }
    }

    func applyAllRules() {
        for rule in ruleSuggestions {
            applyRule(rule)
        }
    }

    // MARK: - Budget Generation

    func loadIncomeEstimate() {
        do {
            // Average income across last 3 months, excluding user-removed sources
            var total = 0.0
            var monthsWithIncome = 0
            let effectiveMonth = currentMonth.isEmpty ? DateHelpers.monthString() : currentMonth
            var m = effectiveMonth
            for _ in 0..<3 {
                let txns = try DatabaseManager.shared.fetchIncomeTransactions(forMonth: m)
                let included = txns.filter { !excludedIncomeIds.contains($0.id) }
                let income = included.reduce(0.0) { $0 + $1.amount }
                if income > 0 {
                    total += income
                    monthsWithIncome += 1
                }
                m = DateHelpers.previousMonth(from: m)
            }
            if monthsWithIncome > 0 {
                monthlyIncome = String(format: "%.0f", total / Double(monthsWithIncome))
            }
        } catch {
            // Silently fail
        }
    }

    func loadIncomeBreakdown() {
        let effectiveMonth = currentMonth.isEmpty ? DateHelpers.monthString() : currentMonth
        do {
            incomeTransactions = try DatabaseManager.shared.fetchIncomeTransactions(forMonth: effectiveMonth)
        } catch {
            incomeTransactions = []
        }
    }

    func toggleIncomeExclusion(_ id: UUID) {
        if excludedIncomeIds.contains(id) {
            excludedIncomeIds.remove(id)
        } else {
            excludedIncomeIds.insert(id)
        }
        // Persist
        if let data = try? JSONEncoder().encode(excludedIncomeIds) {
            UserDefaults.standard.set(data, forKey: "excludedIncomeIds")
        }
        // Recalculate
        loadIncomeEstimate()
    }

    func isIncomeExcluded(_ id: UUID) -> Bool {
        excludedIncomeIds.contains(id)
    }

    func generateBudget() async {
        guard isAPIKeyConfigured else {
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Please enter your Claude API key first."
            return
        }
        guard !isOverCap else {
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Monthly spending cap of $\(String(format: "%.2f", monthlyCap)) reached. Resets next month."
            return
        }
        guard let income = Double(monthlyIncome), income > 0 else {
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Please enter a valid monthly income."
            return
        }

        await MainActor.run {
            isLoadingBudgetGeneration = true
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = nil
            budgetGenerationResponse = ""
            budgetAllocations = []
        }

        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            // Get 3-month spending history
            var months: [String] = []
            var m = currentMonth
            for _ in 0..<3 {
                months.append(m)
                m = DateHelpers.previousMonth(from: m)
            }
            let spendingHistory = try DatabaseManager.shared.fetchSpendingByCategory(forMonths: months)

            let prompt = ClaudeAPIService.buildBudgetGenerationPrompt(
                monthlyIncome: income,
                style: budgetStyle,
                categories: categories,
                spendingHistory: spendingHistory
            )
            let result = try await aiService.generateBudget(apiKey: apiKey, prompt: prompt)
            recordUsage(inputTokens: result.inputTokens, outputTokens: result.outputTokens)

            await MainActor.run {
                budgetGenerationResponse = result.text
                budgetAllocations = result.allocations
                isLoadingBudgetGeneration = false
                pageChatStates[.categories, default: PageChatState()].isExpanded = true
            }
        } catch {
            await MainActor.run {
                pageChatStates[.categories, default: PageChatState()].aiErrorMessage = error.localizedDescription
                isLoadingBudgetGeneration = false
            }
        }
    }

    func applyGeneratedBudget() {
        do {
            var categories = try DatabaseManager.shared.fetchCategories()
            let colors = ["#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FFEAA7",
                          "#DDA0DD", "#98D8C8", "#F7DC6F", "#BB8FCE", "#85C1E9"]

            for allocation in budgetAllocations {
                let catName = allocation.category.replacingOccurrences(of: "[NEW] ", with: "")

                if let idx = categories.firstIndex(where: {
                    $0.name.lowercased() == catName.lowercased()
                }) {
                    // Update existing category
                    categories[idx].monthlyBudget = allocation.amount
                    try DatabaseManager.shared.saveCategory(categories[idx])
                } else {
                    // Create new category
                    let newCat = BudgetCategory(
                        id: UUID(),
                        name: catName,
                        monthlyBudget: allocation.amount,
                        colorHex: colors.randomElement() ?? "#4ECDC4",
                        sortOrder: categories.count,
                        isArchived: false,
                        lastModifiedAt: Date(),
                        cloudKitRecordName: nil,
                        cloudKitSystemFields: nil,
                        isDeleted: false
                    )
                    try DatabaseManager.shared.saveCategory(newCat)
                    categories.append(newCat)
                }
            }
            budgetAllocations = []
            budgetGenerationResponse = "Budget applied successfully!"
        } catch {
            pageChatStates[.categories, default: PageChatState()].aiErrorMessage = "Failed to apply budget: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto-Categorize Transactions

    func categorizeTransactions() async {
        guard isAPIKeyConfigured else {
            pageChatStates[.transactions, default: PageChatState()].aiErrorMessage = "Please enter your Claude API key first."
            return
        }
        guard !isOverCap else {
            pageChatStates[.transactions, default: PageChatState()].aiErrorMessage = "Monthly spending cap of $\(String(format: "%.2f", monthlyCap)) reached. Resets next month."
            return
        }

        await MainActor.run {
            isLoadingCategorization = true
            pageChatStates[.transactions, default: PageChatState()].aiErrorMessage = nil
            categorizationResponse = ""
            categorizationSuggestions = []
        }

        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            // Gather uncategorized transactions from last 3 months
            var transactions: [Transaction] = []
            var m = currentMonth
            for _ in 0..<3 {
                transactions.append(contentsOf: try DatabaseManager.shared.fetchUncategorizedTransactions(forMonth: m))
                m = DateHelpers.previousMonth(from: m)
            }

            guard !transactions.isEmpty else {
                await MainActor.run {
                    categorizationResponse = "No uncategorized transactions found."
                    isLoadingCategorization = false
                }
                return
            }

            // Cap at 50 transactions per request to avoid timeouts
            let totalCount = transactions.count
            if transactions.count > 50 {
                transactions = Array(transactions.prefix(50))
            }

            let prompt = ClaudeAPIService.buildCategorizationPrompt(
                currentMonth: currentMonth,
                categories: categories,
                transactions: transactions
            )
            let result = try await aiService.categorizeTransactions(apiKey: apiKey, prompt: prompt)
            recordUsage(inputTokens: result.inputTokens, outputTokens: result.outputTokens)

            // Match AI suggestions back to actual transaction UUIDs.
            // Use progressively looser matching to handle AI truncation/reformatting.
            var matched = result.categorizations
            var usedTxnIds = Set<UUID>()

            for i in matched.indices {
                let aiDesc = matched[i].transactionDescription.lowercased().trimmingCharacters(in: .whitespaces)
                let aiAmount = matched[i].amount

                // Find best match: exact → starts-with → contains → amount-only
                let candidate = transactions.first(where: { txn in
                    guard !usedTxnIds.contains(txn.id) else { return false }
                    guard abs(abs(txn.amount) - aiAmount) < 0.01 else { return false }
                    return txn.description.lowercased() == aiDesc
                }) ?? transactions.first(where: { txn in
                    guard !usedTxnIds.contains(txn.id) else { return false }
                    guard abs(abs(txn.amount) - aiAmount) < 0.01 else { return false }
                    let dbDesc = txn.description.lowercased()
                    return dbDesc.hasPrefix(aiDesc) || aiDesc.hasPrefix(dbDesc)
                }) ?? transactions.first(where: { txn in
                    guard !usedTxnIds.contains(txn.id) else { return false }
                    guard abs(abs(txn.amount) - aiAmount) < 0.01 else { return false }
                    let dbDesc = txn.description.lowercased()
                    return dbDesc.contains(aiDesc) || aiDesc.contains(dbDesc)
                })

                if let txn = candidate {
                    matched[i].transactionId = txn.id
                    usedTxnIds.insert(txn.id)
                }
            }

            await MainActor.run {
                var responseText = result.text
                if totalCount > 50 {
                    responseText += "\n\n*Showing 50 of \(totalCount) uncategorized transactions. Run again after applying to categorize more.*"
                }
                categorizationResponse = responseText
                categorizationSuggestions = matched.filter { $0.transactionId != nil }
                isLoadingCategorization = false
                pageChatStates[.transactions, default: PageChatState()].isExpanded = true
            }
        } catch {
            await MainActor.run {
                pageChatStates[.transactions, default: PageChatState()].aiErrorMessage = error.localizedDescription
                isLoadingCategorization = false
            }
        }
    }

    func applyCategorization(_ item: ClaudeAPIService.CategorizationSuggestion) {
        guard let txnId = item.transactionId else { return }
        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            let categoryName = item.category.replacingOccurrences(of: "[NEW] ", with: "")

            // Find existing category or create a new one
            let category: BudgetCategory
            if let existing = categories.first(where: {
                $0.name.lowercased() == categoryName.lowercased()
            }) {
                category = existing
            } else {
                // Create the new category suggested by AI
                let colors = ["#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FFEAA7",
                              "#DDA0DD", "#98D8C8", "#F7DC6F", "#BB8FCE", "#85C1E9"]
                var newCat = BudgetCategory(
                    id: UUID(),
                    name: categoryName,
                    monthlyBudget: 0,
                    colorHex: colors.randomElement() ?? "#4ECDC4",
                    sortOrder: categories.count,
                    isArchived: false,
                    lastModifiedAt: Date(),
                    cloudKitRecordName: nil,
                    cloudKitSystemFields: nil,
                    isDeleted: false
                )
                try DatabaseManager.shared.saveCategory(newCat)
                category = newCat
            }

            try DatabaseManager.shared.updateTransactionCategory(txnId, categoryId: category.id, isManual: true)
            categorizationSuggestions.removeAll { $0.id == item.id }
        } catch {
            pageChatStates[.transactions, default: PageChatState()].aiErrorMessage = "Failed to categorize: \(error.localizedDescription)"
        }
    }

    func applyAllCategorizations() {
        for item in categorizationSuggestions {
            applyCategorization(item)
        }
    }

    /// Automatically categorize all uncategorized transactions in batches.
    /// Runs categorize → apply all → repeat until none remain or cap is hit.
    func autoCategorizeAll() async {
        guard !autoCategorizeRunning else { return }

        await MainActor.run {
            autoCategorizeRunning = true
            autoCategorizeProgress = "Starting..."
        }

        var batchNumber = 0
        var totalCategorized = 0

        while autoCategorizeRunning {
            batchNumber += 1

            // Check remaining uncategorized count
            var remaining = 0
            var m = currentMonth
            for _ in 0..<3 {
                remaining += (try? DatabaseManager.shared.fetchUncategorizedTransactions(forMonth: m).count) ?? 0
                m = DateHelpers.previousMonth(from: m)
            }

            guard remaining > 0 else {
                await MainActor.run {
                    autoCategorizeProgress = "Done! Categorized \(totalCategorized) transactions."
                    autoCategorizeRunning = false
                    isLoadingCategorization = false
                }
                return
            }

            await MainActor.run {
                autoCategorizeProgress = "Batch \(batchNumber): \(remaining) remaining..."
            }

            // Run categorization
            await categorizeTransactions()

            // Check if we got results
            guard !categorizationSuggestions.isEmpty else {
                await MainActor.run {
                    autoCategorizeProgress = "Done after \(batchNumber) batches. Categorized \(totalCategorized) transactions."
                    autoCategorizeRunning = false
                }
                return
            }

            // Check cap
            guard !isOverCap else {
                await MainActor.run {
                    autoCategorizeProgress = "Spending cap reached after \(totalCategorized) transactions. Apply remaining suggestions manually."
                    autoCategorizeRunning = false
                }
                return
            }

            // Apply all suggestions
            let count = categorizationSuggestions.count
            applyAllCategorizations()
            totalCategorized += count

            await MainActor.run {
                autoCategorizeProgress = "Batch \(batchNumber) done: applied \(count) (\(totalCategorized) total)"
            }
        }
    }

    func stopAutoCategorize() {
        autoCategorizeRunning = false
    }

    // MARK: - Usage Tracking

    private func currentCalendarMonth() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        return fmt.string(from: Date())
    }

    private func loadUsage() -> (month: String, spend: Double) {
        let month = UserDefaults.standard.string(forKey: "claudeUsageMonth") ?? ""
        let spend = UserDefaults.standard.double(forKey: "claudeUsageSpendUSD")
        return (month, spend)
    }

    private func recordUsage(inputTokens: Int, outputTokens: Int) {
        // Sonnet pricing: $3/M input, $15/M output
        let cost = Double(inputTokens) * 3.0 / 1_000_000 + Double(outputTokens) * 15.0 / 1_000_000
        let current = currentCalendarMonth()
        let (savedMonth, savedSpend) = loadUsage()
        let newSpend = (savedMonth == current ? savedSpend : 0) + cost
        UserDefaults.standard.set(current, forKey: "claudeUsageMonth")
        UserDefaults.standard.set(newSpend, forKey: "claudeUsageSpendUSD")
    }
}

private extension Double {
    /// Returns self if non-zero, otherwise nil (for defaulting UserDefaults 0 values).
    var nonZero: Double? { self == 0 ? nil : self }
}
