import SwiftUI

struct InsightsView: View {
    @Binding var selectedMonth: String
    @State private var viewModel = InsightsViewModel()
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
