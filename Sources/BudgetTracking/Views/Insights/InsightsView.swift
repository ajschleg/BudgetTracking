import SwiftUI

struct InsightsView: View {
    @Binding var selectedMonth: String
    @Bindable var viewModel: InsightsViewModel

    var body: some View {
        PageWithChatBar(
            viewModel: viewModel,
            actions: [
                AIChatAction(label: "Get Insights", icon: "sparkles") {
                    await viewModel.askAI()
                }
            ],
            page: .insights
        ) {
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
                                    InsightCardView(insight: insight) { txnId in
                                        viewModel.dismissReturn(txnId)
                                    }
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Budget Insights", systemImage: "lightbulb.fill")
                    }

                    // API key not configured message
                    if !viewModel.isAPIKeyConfigured {
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
