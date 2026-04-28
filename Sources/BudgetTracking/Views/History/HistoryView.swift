import SwiftUI

struct HistoryView: View {
    @Binding var selectedMonth: String
    @Binding var selectedItem: SidebarItem?
    @Bindable var aiViewModel: InsightsViewModel
    @State private var viewModel = HistoryViewModel()
    @State private var selectedHistoryMonth: String?

    var body: some View {
        VStack(spacing: 0) {
        HSplitView {
            // Month list
            VStack(alignment: .leading) {
                Text("Monthly History")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 12)

                if viewModel.months.isEmpty {
                    VStack {
                        Spacer()
                        Text("No history yet.\nImport statements to\nbuild your history.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(viewModel.months, selection: $selectedHistoryMonth) { summary in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(DateHelpers.displayMonth(summary.month))
                                    .fontWeight(.medium)
                                Text("\(summary.fileCount) files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(CurrencyFormatter.format(summary.totalSpent))
                                    .monospacedDigit()
                                Text("\(Int(summary.percentage * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(
                                        ColorThresholds.color(forPercentage: summary.percentage)
                                    )
                            }
                        }
                        .tag(summary.month)
                    }
                }
            }
            .frame(minWidth: 250)

            // Detail view
            if let month = selectedHistoryMonth {
                MonthDetailView(month: month) {
                    // Open in Dashboard: switch the active month and
                    // jump to the Dashboard tab.
                    selectedMonth = month
                    selectedItem = .dashboard
                }
            } else {
                VStack {
                    Image(systemName: "calendar")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a month to view details")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

            if aiViewModel.isAPIKeyConfigured {
                AIChatBar(
                    viewModel: aiViewModel,
                    actions: [
                        AIChatAction(label: "Analyze Trends", icon: "sparkles") {
                            await aiViewModel.askAI(page: .history)
                        }
                    ],
                    page: .history
                )
            }
        }
        .navigationTitle("History")
        .onAppear {
            viewModel.load()
            aiViewModel.load(month: selectedMonth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load()
        }
    }
}

struct MonthDetailView: View {
    let month: String
    /// Optional callback for jumping to this month on the Dashboard.
    /// Hidden when nil so MonthDetailView can still be used standalone.
    var onOpenInDashboard: (() -> Void)?
    @State private var viewModel = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text(DateHelpers.displayMonth(month))
                        .font(.title)
                        .fontWeight(.bold)
                    Spacer()
                    if let onOpenInDashboard {
                        Button(action: onOpenInDashboard) {
                            Label("Open in Dashboard", systemImage: "chart.bar.fill")
                        }
                        .buttonStyle(.bordered)
                        .help("Switch the Dashboard to \(DateHelpers.displayMonth(month))")
                    }
                }
                .padding(.horizontal)
                .padding(.top)

                OverallBudgetBar(
                    spent: viewModel.totalSpent,
                    budget: viewModel.totalBudget,
                    percentage: viewModel.overallPercentage
                )
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                LazyVStack(spacing: 12) {
                    ForEach(viewModel.categories) { category in
                        CategoryBudgetBar(
                            category: category,
                            spent: viewModel.spending(for: category),
                            percentage: viewModel.percentage(for: category)
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 20)
        }
        .onAppear { viewModel.load(month: month) }
    }
}
