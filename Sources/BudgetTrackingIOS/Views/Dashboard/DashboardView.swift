import SwiftUI

/// iOS dashboard: month selector + overall budget card + per-category rows.
/// Reads the same DashboardViewModel as macOS so totals stay in sync once
/// CloudKit propagates data from the Mac.
struct DashboardView: View {
    let syncEngine: SyncEngine
    let lanSyncEngine: LANSyncEngine
    @State private var viewModel = DashboardViewModel()
    @State private var selectedMonth: String = DateHelpers.monthString()

    /// Bumped each time we observe .localDataDidChange so the dashboard
    /// reloads after CloudKit applies a remote record. The notification
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        LANSyncStatusButton(lanSyncEngine: lanSyncEngine)
                        SyncStatusIndicator(syncEngine: syncEngine)
                    }
                }
            }
            .refreshable { viewModel.load(month: selectedMonth) }
            .task(id: "\(selectedMonth)-\(dataChangeCounter)") {
                viewModel.load(month: selectedMonth)
            }
            .task {
                // Listen for CloudKit-applied changes; bumping the counter
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

private struct SyncStatusIndicator: View {
    let syncEngine: SyncEngine

    var body: some View {
        switch syncEngine.status {
        case .idle:
            Image(systemName: "icloud.fill")
                .foregroundStyle(.green)
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.red)
        case .noAccount:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
        }
    }
}

/// Tappable status pill for LAN sync. Shows a Wi-Fi-style icon colored by
/// state, and on tap either kicks off a manual `syncNow()` (when a peer
/// is connected) or surfaces a small popover explaining why nothing is
/// happening (no peer, sync disabled, error).
private struct LANSyncStatusButton: View {
    let lanSyncEngine: LANSyncEngine
    @State private var showStatusPopover = false

    private var icon: String {
        switch lanSyncEngine.status {
        case .disabled: return "wifi.slash"
        case .searching: return "wifi"
        case .connected: return "wifi"
        case .syncing: return "wifi"
        case .error: return "wifi.exclamationmark"
        }
    }

    private var iconColor: Color {
        switch lanSyncEngine.status {
        case .disabled: return .secondary
        case .searching: return .orange
        case .connected: return .green
        case .syncing: return .blue
        case .error: return .red
        }
    }

    private var isSyncing: Bool {
        if case .syncing = lanSyncEngine.status { return true }
        return false
    }

    var body: some View {
        Button {
            if lanSyncEngine.connectedPeerName != nil {
                lanSyncEngine.syncNow()
            } else {
                showStatusPopover = true
            }
        } label: {
            ZStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .opacity(isSyncing ? 0.4 : 1)
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .popover(isPresented: $showStatusPopover, arrowEdge: .top) {
            LANStatusPopover(lanSyncEngine: lanSyncEngine)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct LANStatusPopover: View {
    let lanSyncEngine: LANSyncEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAN sync")
                .font(.headline)
            Text(detailMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Enable LAN sync", isOn: Binding(
                get: { lanSyncEngine.isEnabled },
                set: { lanSyncEngine.isEnabled = $0 }
            ))
        }
        .padding(16)
        .frame(width: 280)
    }

    private var detailMessage: String {
        switch lanSyncEngine.status {
        case .disabled:
            return "Discover your Mac on the same Wi-Fi and pull categories and transactions over the local network. No iCloud required."
        case .searching:
            return "Looking for your Mac on this Wi-Fi… Make sure BudgetTracking is open on the Mac with LAN sync enabled."
        case .connected(let name):
            return "Connected to \(name). Tap the Wi-Fi icon to sync now."
        case .syncing(let name):
            return "Syncing with \(name)…"
        case .error(let msg):
            return "LAN sync error: \(msg)"
        }
    }
}

// MARK: - Month Selector

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
            }

            ProgressBar(progress: pct, color: fillColor)

            Text(remaining >= 0
                 ? "\(CurrencyFormatter.format(remaining)) left"
                 : "\(CurrencyFormatter.format(abs(remaining))) over")
                .font(.caption2)
                .foregroundStyle(remaining >= 0 ? Color.secondary : Color.red)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            Text("Open BudgetTracking on your Mac so iCloud can sync your categories and transactions to this device.")
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

// No #Preview here: DashboardView needs a SyncEngine, and instantiating
// one in a preview kicks off real CloudKit traffic. Run the app instead.
