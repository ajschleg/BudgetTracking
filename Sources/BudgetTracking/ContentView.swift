import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case income = "Income"
    case transactions = "Transactions"
    case importStatements = "Import"
    case categories = "Categories"
    case history = "History"
    case insights = "Insights"
    case sync = "Sync"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .income: return "banknote"
        case .transactions: return "list.bullet.rectangle"
        case .importStatements: return "square.and.arrow.down"
        case .categories: return "folder.fill"
        case .history: return "clock.fill"
        case .insights: return "lightbulb.fill"
        case .sync: return "arrow.triangle.2.circlepath"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    @State private var selectedItem: SidebarItem? = .dashboard
    @State private var selectedMonth: String = DateHelpers.monthString()
    @State private var insightsViewModel = InsightsViewModel()
    @AppStorage("isIncomePageEnabled") private var isIncomePageEnabled = false

    let syncEngine: SyncEngine
    let shareManager: ShareManager
    let lanSyncEngine: LANSyncEngine

    private var visibleSidebarItems: [SidebarItem] {
        SidebarItem.allCases.filter { item in
            if item == .income { return isIncomePageEnabled }
            return true
        }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleSidebarItems, selection: $selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)

            // Sync status indicators at bottom of sidebar
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    cloudSyncStatusDot
                    Text(cloudSyncStatusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    lanSyncEngine.syncNow()
                } label: {
                    HStack(spacing: 6) {
                        lanSyncStatusDot
                        Text(lanSyncStatusLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if lanSyncEngine.connectedPeerName != nil {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(lanSyncEngine.connectedPeerName == nil)
                .help(lanSyncEngine.connectedPeerName != nil ? "Sync now" : "No peer connected")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } detail: {
            switch selectedItem {
            case .dashboard:
                DashboardView(selectedMonth: $selectedMonth, selectedItem: $selectedItem)
            case .income:
                IncomeView(selectedMonth: $selectedMonth)
            case .transactions:
                TransactionsListView(selectedMonth: $selectedMonth, aiViewModel: insightsViewModel)
            case .importStatements:
                ImportView(selectedMonth: $selectedMonth)
            case .categories:
                CategoriesSettingsView(aiViewModel: insightsViewModel)
            case .history:
                HistoryView(selectedMonth: $selectedMonth)
            case .insights:
                InsightsView(selectedMonth: $selectedMonth, viewModel: insightsViewModel)
            case .sync:
                SyncSettingsView(syncEngine: syncEngine, shareManager: shareManager, lanSyncEngine: lanSyncEngine)
            case .settings:
                SettingsView(aiViewModel: insightsViewModel)
            case nil:
                Text("Select an item from the sidebar")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    lanSyncEngine.syncNow()
                } label: {
                    HStack(spacing: 4) {
                        lanSyncToolbarIcon
                        if case .syncing(let name) = lanSyncEngine.status {
                            Text("Syncing with \(name)…")
                                .font(.caption)
                        }
                    }
                }
                .disabled(lanSyncEngine.connectedPeerName == nil)
                .help(lanSyncToolbarHelp)
            }
        }
    }

    // MARK: - Toolbar Sync Button

    @ViewBuilder
    private var lanSyncToolbarIcon: some View {
        switch lanSyncEngine.status {
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.green)
        case .searching:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        default:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        }
    }

    private var lanSyncToolbarHelp: String {
        if lanSyncEngine.connectedPeerName != nil {
            return "Sync now with \(lanSyncEngine.connectedPeerName!)"
        }
        switch lanSyncEngine.status {
        case .disabled: return "LAN sync is disabled — enable in Sync settings"
        case .searching: return "Searching for peers…"
        default: return "No peer connected"
        }
    }

    // MARK: - Cloud Sync Status

    @ViewBuilder
    private var cloudSyncStatusDot: some View {
        switch syncEngine.status {
        case .idle:
            Image(systemName: "icloud.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .syncing:
            ProgressView()
                .controlSize(.mini)
        case .error:
            Image(systemName: "icloud.slash")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        case .noAccount:
            Image(systemName: "icloud.slash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var cloudSyncStatusLabel: String {
        switch syncEngine.status {
        case .idle: return "iCloud synced"
        case .syncing: return "iCloud syncing..."
        case .error: return "iCloud error"
        case .noAccount: return "No iCloud"
        }
    }

    // MARK: - LAN Sync Status

    @ViewBuilder
    private var lanSyncStatusDot: some View {
        switch lanSyncEngine.status {
        case .disabled:
            Image(systemName: "wifi.slash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .searching:
            Image(systemName: "wifi")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .connected:
            Image(systemName: "wifi")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .syncing:
            ProgressView()
                .controlSize(.mini)
        case .error:
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        }
    }

    private var lanSyncStatusLabel: String {
        switch lanSyncEngine.status {
        case .disabled: return "LAN sync off"
        case .searching: return "Searching..."
        case .connected(let name): return "LAN: \(name)"
        case .syncing(let name): return "LAN syncing with \(name)..."
        case .error(let msg): return "LAN: \(msg)"
        }
    }
}
