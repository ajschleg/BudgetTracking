import Foundation
import SwiftUI

@Observable
final class InsightsViewModel {
    var insights: [BudgetInsight] = []
    var isLoadingInsights = false
    var errorMessage: String?

    // AI Assistant state
    var userQuestion: String = ""
    var aiResponse: String = ""
    var isLoadingAI = false
    var aiErrorMessage: String?

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
            insights = try engine.generateInsights(forMonth: month)
        } catch {
            errorMessage = error.localizedDescription
            insights = []
        }

        isLoadingInsights = false
    }

    func askAI() async {
        guard isAPIKeyConfigured else {
            aiErrorMessage = "Please enter your Claude API key first."
            return
        }
        guard !isOverCap else {
            aiErrorMessage = "Monthly spending cap of $\(String(format: "%.2f", monthlyCap)) reached. Resets next month."
            return
        }

        await MainActor.run {
            isLoadingAI = true
            aiErrorMessage = nil
            aiResponse = ""
        }

        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            var summary = try ClaudeAPIService.buildSpendingSummary(
                currentMonth: currentMonth,
                categories: categories
            )
            let question = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty {
                summary += "\n\n## User Question\n\(question)"
            }
            let result = try await aiService.analyze(apiKey: apiKey, spendingSummary: summary)
            recordUsage(inputTokens: result.inputTokens, outputTokens: result.outputTokens)
            await MainActor.run {
                aiResponse = result.text
                isLoadingAI = false
            }
        } catch {
            await MainActor.run {
                aiErrorMessage = error.localizedDescription
                isLoadingAI = false
            }
        }
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
