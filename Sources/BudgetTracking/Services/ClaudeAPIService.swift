import Foundation

/// Service for calling the Claude API to get AI-powered budget analysis.
actor ClaudeAPIService {

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-sonnet-4-20250514"
    private let apiVersion = "2023-06-01"

    struct AnalysisResult {
        let text: String
        let suggestions: [BudgetSuggestion]
        let inputTokens: Int
        let outputTokens: Int
    }

    struct RuleSuggestion: Codable, Identifiable {
        var id = UUID()
        let keyword: String
        let category: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case keyword, category, reason
        }
    }

    struct RuleResult {
        let text: String
        let rules: [RuleSuggestion]
        let inputTokens: Int
        let outputTokens: Int
    }

    struct CategorizationSuggestion: Codable, Identifiable {
        var id = UUID()
        let transactionDescription: String
        let transactionDate: String
        let amount: Double
        let category: String
        let reason: String
        var transactionId: UUID?

        enum CodingKeys: String, CodingKey {
            case transactionDescription = "description"
            case transactionDate = "date"
            case amount, category, reason
        }
    }

    struct CategorizationResult {
        let text: String
        let categorizations: [CategorizationSuggestion]
        let inputTokens: Int
        let outputTokens: Int
    }

    struct BudgetSuggestion: Codable, Identifiable {
        var id = UUID()
        let category: String
        let currentBudget: Double
        let suggestedBudget: Double
        let reason: String

        enum CodingKeys: String, CodingKey {
            case category, currentBudget, suggestedBudget, reason
        }
    }

    /// Analyze spending data and return natural-language insights.
    func analyze(apiKey: String, spendingSummary: String) async throws -> AnalysisResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": spendingSummary]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw ClaudeAPIError.invalidAPIKey
            } else if httpResponse.statusCode == 429 {
                throw ClaudeAPIError.rateLimited
            }
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String
        else {
            throw ClaudeAPIError.unexpectedResponseFormat
        }

        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        let (displayText, suggestions) = Self.parseResponse(text)
        return AnalysisResult(text: displayText, suggestions: suggestions, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Build an aggregated, privacy-safe spending summary for the AI prompt.
    /// Only sends category names and monthly totals — no transaction descriptions or merchants.
    static func buildSpendingSummary(
        currentMonth: String,
        categories: [BudgetCategory],
        monthsOfHistory: Int = 12
    ) throws -> String {
        let allMonths = try DatabaseManager.shared.fetchAllSnapshotMonths()

        // Collect up to N months of history
        var months: [String] = [currentMonth]
        var month = currentMonth
        for _ in 0..<monthsOfHistory {
            month = DateHelpers.previousMonth(from: month)
            if allMonths.contains(month) {
                months.append(month)
            }
        }

        let spending = try DatabaseManager.shared.fetchSpendingByCategory(forMonths: months)

        var lines: [String] = []
        lines.append("## Current Budget Categories")
        lines.append("| Category | Monthly Budget |")
        lines.append("|----------|---------------|")
        for cat in categories {
            lines.append("| \(cat.name) | $\(String(format: "%.2f", cat.monthlyBudget)) |")
        }

        lines.append("")
        lines.append("## Spending History (by category per month)")
        lines.append("| Month | Category | Spent |")
        lines.append("|-------|----------|-------|")

        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })

        for m in months.sorted() {
            guard let catSpending = spending[m] else { continue }
            for (catId, amount) in catSpending.sorted(by: { $0.value > $1.value }) {
                let name = categoryMap[catId] ?? "Unknown"
                lines.append("| \(DateHelpers.displayMonth(m)) | \(name) | $\(String(format: "%.2f", amount)) |")
            }
        }

        // Add uncategorized spending
        let uncategorized = try DatabaseManager.shared.fetchUncategorizedSpending(forMonth: currentMonth)
        if uncategorized > 0 {
            lines.append("")
            lines.append("Uncategorized spending this month: $\(String(format: "%.2f", uncategorized))")
        }

        lines.append("")
        lines.append("Current month: \(DateHelpers.displayMonth(currentMonth))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private var systemPrompt: String {
        """
        You are a personal budget analyst. The user will provide their budget categories with \
        monthly budgets and historical spending data by category and month.

        Analyze the data and provide:
        1. **Surprise Expense Risks**: Identify expenses that may be coming up based on seasonal \
        patterns or annual cycles that the user may not have budgeted for.
        2. **Seasonal Patterns**: Point out categories with clear seasonal variation (e.g., heating \
        costs higher in winter).
        3. **Budget Adjustment Suggestions**: Categories where the budget is consistently too low \
        or too high based on actual spending.
        4. **Missing Categories**: If spending patterns suggest categories that should exist but don't.

        Be concise and actionable. Use specific dollar amounts. Focus on the most impactful insights first.

        IMPORTANT: If you have any concrete budget adjustment suggestions, end your response with \
        a line containing exactly "---SUGGESTIONS---" followed by a JSON array of objects with \
        these fields: "category" (exact category name from the user's list), "currentBudget" (their \
        current monthly budget), "suggestedBudget" (your recommended amount), "reason" (brief explanation). \
        Only include suggestions for existing categories where you recommend a specific dollar change. Example:
        ---SUGGESTIONS---
        [{"category":"Utilities","currentBudget":100,"suggestedBudget":180,"reason":"Winter months average $175"}]
        """
    }

    /// Parse the AI response, splitting display text from the structured suggestions block.
    static func parseResponse(_ raw: String) -> (text: String, suggestions: [BudgetSuggestion]) {
        let separator = "---SUGGESTIONS---"
        guard let range = raw.range(of: separator) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        let displayText = String(raw[raw.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString = String(raw[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = jsonString.data(using: .utf8),
              let suggestions = try? JSONDecoder().decode([BudgetSuggestion].self, from: jsonData)
        else {
            return (displayText, [])
        }

        return (displayText, suggestions)
    }

    // MARK: - Rule Suggestions

    /// Ask the AI to suggest categorization rules based on uncategorized transactions.
    func suggestRules(apiKey: String, prompt: String) async throws -> RuleResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": ruleSystemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 { throw ClaudeAPIError.invalidAPIKey }
            if httpResponse.statusCode == 429 { throw ClaudeAPIError.rateLimited }
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String
        else {
            throw ClaudeAPIError.unexpectedResponseFormat
        }

        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        let (displayText, rules) = Self.parseRuleResponse(text)
        return RuleResult(text: displayText, rules: rules, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Build a prompt with uncategorized transactions and existing categories for rule suggestion.
    static func buildRulePrompt(
        currentMonth: String,
        categories: [BudgetCategory]
    ) throws -> String {
        var lines: [String] = []

        lines.append("## Existing Categories")
        for cat in categories {
            lines.append("- \(cat.name)")
        }

        // Fetch uncategorized transactions (last 3 months)
        var months = [currentMonth]
        var m = currentMonth
        for _ in 0..<2 {
            m = DateHelpers.previousMonth(from: m)
            months.append(m)
        }

        lines.append("")
        lines.append("## Uncategorized Transactions")
        lines.append("| Date | Description | Amount |")
        lines.append("|------|-------------|--------|")

        var hasTransactions = false
        for month in months.sorted() {
            let transactions = try DatabaseManager.shared.fetchUncategorizedTransactions(forMonth: month)
            for txn in transactions {
                hasTransactions = true
                let dateStr = DateHelpers.shortDate(txn.date)
                lines.append("| \(dateStr) | \(txn.description) | $\(String(format: "%.2f", abs(txn.amount))) |")
            }
        }

        if !hasTransactions {
            // Also include categorized transactions so AI can suggest rules for those
            lines.append("(No uncategorized transactions found)")
            lines.append("")
            lines.append("## Recent Transactions (already categorized)")
            lines.append("| Description | Category | Amount |")
            lines.append("|-------------|----------|--------|")
            let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
            let transactions = try DatabaseManager.shared.fetchRecentTransactions(forMonth: currentMonth)
            for txn in transactions.prefix(50) {
                let catName = txn.categoryId.flatMap { categoryMap[$0] } ?? "Uncategorized"
                lines.append("| \(txn.description) | \(catName) | $\(String(format: "%.2f", abs(txn.amount))) |")
            }
        }

        lines.append("")
        lines.append("Current month: \(DateHelpers.displayMonth(currentMonth))")

        return lines.joined(separator: "\n")
    }

    private var ruleSystemPrompt: String {
        """
        You are a personal budget assistant. The user will provide their budget categories and \
        a list of uncategorized (or recently categorized) transactions.

        Suggest categorization rules — keyword patterns that can automatically assign transactions \
        to categories. A rule matches when the transaction description contains the keyword \
        (case-insensitive substring match).

        Choose keywords that are specific enough to avoid false matches but general enough to catch \
        variations. For example, use "COSTCO" rather than "COSTCO WHOLESALE #1234".

        Briefly explain your reasoning, then end your response with a line containing exactly \
        "---RULES---" followed by a JSON array of objects with these fields:
        - "keyword": the keyword to match (case-insensitive)
        - "category": exact category name from the user's list
        - "reason": brief explanation

        Example:
        ---RULES---
        [{"keyword":"COSTCO","category":"Grocery","reason":"Costco purchases are typically groceries"}]
        """
    }

    static func parseRuleResponse(_ raw: String) -> (text: String, rules: [RuleSuggestion]) {
        let separator = "---RULES---"
        guard let range = raw.range(of: separator) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        let displayText = String(raw[raw.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString = String(raw[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = jsonString.data(using: .utf8),
              let rules = try? JSONDecoder().decode([RuleSuggestion].self, from: jsonData)
        else {
            return (displayText, [])
        }

        return (displayText, rules)
    }

    // MARK: - Auto-Categorize Transactions

    func categorizeTransactions(apiKey: String, prompt: String) async throws -> CategorizationResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": categorizeSystemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 { throw ClaudeAPIError.invalidAPIKey }
            if httpResponse.statusCode == 429 { throw ClaudeAPIError.rateLimited }
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String
        else {
            throw ClaudeAPIError.unexpectedResponseFormat
        }

        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        let (displayText, categorizations) = Self.parseCategorizationResponse(text)
        return CategorizationResult(text: displayText, categorizations: categorizations, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Build prompt with uncategorized transactions for auto-categorization.
    static func buildCategorizationPrompt(
        currentMonth: String,
        categories: [BudgetCategory],
        transactions: [Transaction]
    ) -> String {
        var lines: [String] = []

        lines.append("## Available Categories")
        for cat in categories {
            lines.append("- \(cat.name)")
        }

        lines.append("")
        lines.append("## Uncategorized Transactions")
        lines.append("| # | Date | Description | Amount |")
        lines.append("|---|------|-------------|--------|")

        for (i, txn) in transactions.enumerated() {
            let dateStr = DateHelpers.shortDate(txn.date)
            lines.append("| \(i + 1) | \(dateStr) | \(txn.description) | $\(String(format: "%.2f", abs(txn.amount))) |")
        }

        lines.append("")
        lines.append("Current month: \(DateHelpers.displayMonth(currentMonth))")

        return lines.joined(separator: "\n")
    }

    private var categorizeSystemPrompt: String {
        """
        You are a personal budget assistant. The user will provide their budget categories and \
        a list of uncategorized transactions.

        For each transaction, determine the most appropriate category based on the description. \
        If none of the existing categories are a good fit, suggest a NEW category name. \
        Prefix new category names with "[NEW] " so the user knows it will be created.

        Keep your text summary VERY brief (2-3 sentences max). The JSON block is the priority.

        CRITICAL RULES:
        - You MUST categorize ALL transactions — do not skip any
        - Copy each transaction description EXACTLY as shown (do not truncate or modify)
        - The JSON block MUST be included — it is more important than the text summary

        End your response with a line containing exactly "---CATEGORIZATIONS---" followed by a \
        JSON array of objects with these fields:
        - "description": the EXACT transaction description copied verbatim from the list
        - "date": the date string from the list
        - "amount": the dollar amount as a number
        - "category": exact category name from the user's list, OR a new name prefixed with "[NEW] "
        - "reason": brief explanation

        Example:
        ---CATEGORIZATIONS---
        [{"description":"COSTCO WHOLESALE","date":"3/15/26","amount":145.67,"category":"Grocery","reason":"Bulk grocery store"},\
        {"description":"HILTON GARDEN INN","date":"3/11/26","amount":49.15,"category":"[NEW] Travel","reason":"Hotel stay"}]
        """
    }

    static func parseCategorizationResponse(_ raw: String) -> (text: String, categorizations: [CategorizationSuggestion]) {
        let separator = "---CATEGORIZATIONS---"
        guard let range = raw.range(of: separator) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        let displayText = String(raw[raw.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString = String(raw[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = jsonString.data(using: .utf8),
              let items = try? JSONDecoder().decode([CategorizationSuggestion].self, from: jsonData)
        else {
            return (displayText, [])
        }

        return (displayText, items)
    }
}

enum ClaudeAPIError: LocalizedError {
    case invalidAPIKey
    case rateLimited
    case invalidResponse
    case unexpectedResponseFormat
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid API key. Please check your Claude API key in the settings above."
        case .rateLimited:
            return "Rate limited. Please wait a moment and try again."
        case .invalidResponse:
            return "Received an invalid response from the API."
        case .unexpectedResponseFormat:
            return "Unexpected response format from the API."
        case .httpError(let code, let body):
            return "API error (\(code)): \(body)"
        }
    }
}
