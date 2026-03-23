import Foundation

/// Service for calling the Claude API to get AI-powered budget analysis.
actor ClaudeAPIService {

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-sonnet-4-20250514"
    private let apiVersion = "2023-06-01"

    struct AnalysisResult {
        let text: String
        let inputTokens: Int
        let outputTokens: Int
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

        return AnalysisResult(text: text, inputTokens: inputTokens, outputTokens: outputTokens)
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
        """
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
