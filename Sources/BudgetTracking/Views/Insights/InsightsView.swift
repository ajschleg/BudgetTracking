import SwiftUI

struct InsightsView: View {
    @Binding var selectedMonth: String
    @Bindable var viewModel: InsightsViewModel

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

                // MARK: - AI Assistant (Ask AI)
                if viewModel.isAPIKeyConfigured {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
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

                            // Error display
                            if let error = viewModel.aiErrorMessage {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .font(.callout)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.red.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            // AI Response
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
                        }
                        .padding(4)
                    } label: {
                        Label("AI Assistant", systemImage: "sparkles")
                    }
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Configure your Claude API key in Settings to enable AI-powered spending analysis.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(4)
                    } label: {
                        Label("AI Assistant", systemImage: "sparkles")
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
