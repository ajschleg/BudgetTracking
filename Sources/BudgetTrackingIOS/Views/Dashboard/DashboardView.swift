import SwiftUI

/// iOS dashboard: month selector + overall budget card + per-category rows.
/// Reads the same DashboardViewModel as macOS; data arrives via the server
/// sync services and .localDataDidChange re-fires the loader.
struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    @State private var selectedMonth: String = DateHelpers.monthString()

    /// Bumped each time we observe .localDataDidChange so the dashboard
    /// reloads after server sync applies a remote record. The notification
    /// itself is fire-and-forget; `id:` on .task is the simplest way to
    /// rerun the loader against a Notification stream without retaining a
    /// subscription token here.
    @State private var dataChangeCounter = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MonthSelector(selectedMonth: $selectedMonth)

                    if let error = viewModel.errorMessage {
                        ErrorCard(message: error)
                    } else if viewModel.categories.isEmpty {
                        EmptyStateCard()
                    } else {
                        OverallBudgetCard(viewModel: viewModel)

                        if viewModel.totalIncome > 0 {
                            IncomeCard(amount: viewModel.totalIncome)
                        }

                        VStack(spacing: 8) {
                            ForEach(viewModel.categories) { category in
                                CategoryRow(category: category, viewModel: viewModel)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Dashboard")
            .refreshable { viewModel.load(month: selectedMonth) }
            .task(id: "\(selectedMonth)-\(dataChangeCounter)") {
                viewModel.load(month: selectedMonth)
            }
            .task {
                // Listen for server-sync-applied changes; bumping the counter
                // re-fires the load .task above on the main actor.
                let center = NotificationCenter.default
                for await _ in center.notifications(named: .localDataDidChange) {
                    dataChangeCounter &+= 1
                }
            }
        }
    }
}

// MARK: - Sync Status Indicators

private struct MonthSelector: View {
    @Binding var selectedMonth: String

    var body: some View {
        HStack {
            Button {
                selectedMonth = DateHelpers.previousMonth(from: selectedMonth)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)

            Spacer()

            VStack(spacing: 2) {
                Text(DateHelpers.displayMonth(selectedMonth))
                    .font(.headline)
                if selectedMonth != DateHelpers.monthString() {
                    Button("Today") {
                        selectedMonth = DateHelpers.monthString()
                    }
                    .font(.caption)
                }
            }

            Spacer()

            Button {
                selectedMonth = DateHelpers.nextMonth(from: selectedMonth)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Overall Budget Card

private struct OverallBudgetCard: View {
    let viewModel: DashboardViewModel

    private var remaining: Double { viewModel.totalBudget - viewModel.totalSpent }
    private var pct: Double { min(viewModel.overallPercentage, 1.0) }
    private var fillColor: Color { ColorThresholds.color(forPercentage: viewModel.overallPercentage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(CurrencyFormatter.format(viewModel.totalSpent))
                    .font(.title2.weight(.semibold))
                Text("of \(CurrencyFormatter.format(viewModel.totalBudget))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProgressBar(progress: pct, color: fillColor)

            HStack {
                Text(remaining >= 0 ? "Remaining" : "Over budget")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(CurrencyFormatter.format(abs(remaining)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(remaining >= 0 ? Color.primary : Color.red)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Income Card

private struct IncomeCard: View {
    let amount: Double

    var body: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            Text("Income this month")
                .font(.subheadline)
            Spacer()
            Text(CurrencyFormatter.format(amount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Category Row

private struct CategoryRow: View {
    let category: BudgetCategory
    let viewModel: DashboardViewModel

    private var spent: Double { viewModel.spending(for: category) }
    private var pct: Double { min(viewModel.percentage(for: category), 1.0) }
    private var rawPct: Double { viewModel.percentage(for: category) }
    private var remaining: Double { category.monthlyBudget - spent }
    private var fillColor: Color { ColorThresholds.color(forPercentage: rawPct) }
    private var dotColor: Color { ColorThresholds.colorFromHex(category.colorHex) }
    private var isExpanded: Bool { viewModel.expandedCategoryId == category.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                Text(category.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(CurrencyFormatter.format(spent)) / \(CurrencyFormatter.format(category.monthlyBudget))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }

            ProgressBar(progress: pct, color: fillColor)

            Text(remaining >= 0
                 ? "\(CurrencyFormatter.format(remaining)) left"
                 : "\(CurrencyFormatter.format(abs(remaining))) over")
                .font(.caption2)
                .foregroundStyle(remaining >= 0 ? Color.secondary : Color.red)

            if isExpanded {
                ExpandedTransactionsList(viewModel: viewModel)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) {
                viewModel.toggleCategory(category.id)
            }
        }
    }
}

/// The month's transactions for the expanded category, newest first —
/// the same drill-in the macOS dashboard offers, view-only on iOS
/// (recategorizing lives in the Transactions tab's picker).
private struct ExpandedTransactionsList: View {
    let viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.vertical, 4)
            if viewModel.expandedTransactions.isEmpty {
                Text("No transactions in this category this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(viewModel.expandedTransactions) { txn in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(txn.date, format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                            .monospacedDigit()
                        Text(txn.merchant ?? txn.description)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(CurrencyFormatter.format(abs(txn.amount)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(txn.amount > 0 ? Color.green : Color.primary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

// MARK: - Progress Bar

private struct ProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemBackground))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(0, proxy.size.width * progress))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Empty / Error States

private struct EmptyStateCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No data yet")
                .font(.headline)
            Text("Connect to your server in the Settings tab (URL + token, then Test Connection) and your categories and transactions will appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// No #Preview here: the view reads DatabaseManager.shared, and previews
// against the real on-disk DB are misleading. Run the app instead.
