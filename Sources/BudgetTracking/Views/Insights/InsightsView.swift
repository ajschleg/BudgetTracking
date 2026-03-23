import SwiftUI

struct InsightsView: View {
    @Binding var selectedMonth: String
    @Bindable var viewModel: InsightsViewModel
    @State private var showAPIKeyField = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Month selector
                MonthSelectorView(selectedMonth: $selectedMonth)
                    .padding(.top)

                // MARK: - On-Device Insights
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        if viewModel.isLoadingInsights {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Analyzing spending patterns...")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                        } else if viewModel.insights.isEmpty {
                            emptyInsightsView
                        } else {
                            ForEach(viewModel.insights) { insight in
                                InsightCardView(insight: insight)
                            }
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Budget Insights", systemImage: "lightbulb.fill")
                }

                // MARK: - AI Assistant
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        // API Key Configuration
                        DisclosureGroup(isExpanded: $showAPIKeyField) {
                            VStack(alignment: .leading, spacing: 8) {
                                SecureField("sk-ant-...", text: $viewModel.apiKey)
                                .textFieldStyle(.roundedBorder)

                                Text("Your API key is stored locally and only used to send aggregated spending data (category names and monthly totals) to Claude for analysis. No transaction descriptions or merchant names are sent.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack(spacing: 6) {
                                Text("API Key")
                                    .font(.subheadline)
                                if viewModel.isAPIKeyConfigured {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                } else {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }

                        Divider()

                        if viewModel.isAPIKeyConfigured {
                            // Usage indicator
                            HStack {
                                Text("Usage this month: $\(String(format: "%.2f", viewModel.monthlySpend)) / $\(String(format: "%.2f", viewModel.monthlyCap)) cap")
                                    .font(.caption)
                                    .foregroundStyle(viewModel.isOverCap ? .red : .secondary)
                                Spacer()
                            }

                            // Question field + Ask AI button
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Ask a question (optional) — e.g. \"What should I budget for taxes?\"",
                                          text: $viewModel.userQuestion, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(1...4)

                                HStack {
                                    Text(viewModel.userQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? "Get a general analysis of your spending patterns."
                                         : "Your question will be answered using your spending data as context.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Button {
                                        Task { await viewModel.askAI() }
                                    } label: {
                                        if viewModel.isLoadingAI {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label("Ask AI", systemImage: "sparkles")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(viewModel.isLoadingAI || viewModel.isOverCap)
                                }
                            }

                            // AI Response
                            if let error = viewModel.aiErrorMessage {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .font(.callout)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.red.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            if !viewModel.aiResponse.isEmpty {
                                Divider()

                                Text(viewModel.aiResponse)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                // Suggested budget changes
                                if !viewModel.suggestions.isEmpty {
                                    Divider()

                                    HStack {
                                        Text("Suggested Changes")
                                            .font(.headline)
                                        Spacer()
                                        Button("Apply All") {
                                            viewModel.applyAllSuggestions()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }

                                    ForEach(viewModel.suggestions) { suggestion in
                                        suggestionCard(suggestion)
                                    }
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Enter your Claude API key above to enable AI-powered spending analysis.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 4) {
                                    Text("Need an API key?")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Link("Get one at console.anthropic.com",
                                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(4)
                } label: {
                    Label("AI Assistant", systemImage: "sparkles")
                }

                // MARK: - Rule Suggestions
                if viewModel.isAPIKeyConfigured {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Analyze your transactions and suggest keyword rules to auto-categorize them.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    Task { await viewModel.suggestRules() }
                                } label: {
                                    if viewModel.isLoadingRules {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label("Suggest Rules", systemImage: "wand.and.stars")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isLoadingRules || viewModel.isOverCap)
                            }

                            if !viewModel.ruleResponse.isEmpty {
                                Divider()

                                Text(viewModel.ruleResponse)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                if !viewModel.ruleSuggestions.isEmpty {
                                    Divider()

                                    HStack {
                                        Text("Suggested Rules")
                                            .font(.headline)
                                        Spacer()
                                        Button("Apply All") {
                                            viewModel.applyAllRules()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }

                                    ForEach(viewModel.ruleSuggestions) { rule in
                                        ruleCard(rule)
                                    }
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Auto-Categorization Rules", systemImage: "text.badge.checkmark")
                    }

                    // MARK: - Auto-Categorize Transactions
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Let AI categorize your uncategorized transactions.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button {
                                    Task { await viewModel.categorizeTransactions() }
                                } label: {
                                    if viewModel.isLoadingCategorization {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label("Categorize", systemImage: "tag.fill")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isLoadingCategorization || viewModel.isOverCap)
                            }

                            if !viewModel.categorizationResponse.isEmpty {
                                Divider()

                                Text(viewModel.categorizationResponse)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                if !viewModel.categorizationSuggestions.isEmpty {
                                    Divider()

                                    HStack {
                                        Text("Suggested Categories")
                                            .font(.headline)
                                        Spacer()
                                        Button("Apply All") {
                                            viewModel.applyAllCategorizations()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }

                                    ForEach(viewModel.categorizationSuggestions) { item in
                                        categorizationCard(item)
                                    }
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Auto-Categorize Transactions", systemImage: "tag.fill")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .navigationTitle("Insights")
        .onAppear { viewModel.load(month: selectedMonth) }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.load(month: newMonth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load(month: selectedMonth)
        }
    }

    // MARK: - Suggestion Card

    private func suggestionCard(_ suggestion: ClaudeAPIService.BudgetSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.category)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text("$\(String(format: "%.0f", suggestion.currentBudget))")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.0f", suggestion.suggestedBudget))")
                        .foregroundStyle(suggestion.suggestedBudget > suggestion.currentBudget ? .red : .green)
                        .fontWeight(.medium)
                }
                .font(.subheadline)
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") {
                withAnimation { viewModel.applySuggestion(suggestion) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Rule Card

    private func ruleCard(_ rule: ClaudeAPIService.RuleSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\"\(rule.keyword)\"")
                        .font(.subheadline.weight(.semibold).monospaced())
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rule.category)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                }
                Text(rule.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") {
                withAnimation { viewModel.applyRule(rule) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Categorization Card

    private func categorizationCard(_ item: ClaudeAPIService.CategorizationSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.transactionDescription)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("$\(String(format: "%.2f", item.amount))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.category.hasPrefix("[NEW] ") {
                        Text(item.category.replacingOccurrences(of: "[NEW] ", with: ""))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    } else {
                        Text(item.category)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") {
                withAnimation { viewModel.applyCategorization(item) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty State

    private var emptyInsightsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("No issues found")
                .font(.headline)
            Text("Your budget looks good for \(DateHelpers.displayMonth(selectedMonth)). As you import more months of data, the insights engine will be able to detect seasonal patterns and recurring expenses.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}
