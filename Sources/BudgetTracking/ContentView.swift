import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case transactions = "Transactions"
    case importStatements = "Import"
    case categories = "Categories"
    case history = "History"
    case sync = "Sync"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .transactions: return "list.bullet.rectangle"
        case .importStatements: return "square.and.arrow.down"
        case .categories: return "folder.fill"
        case .history: return "clock.fill"
        case .sync: return "arrow.triangle.2.circlepath"
        }
    }
}

struct ContentView: View {
    @State private var selectedItem: SidebarItem? = .dashboard
    @State private var selectedMonth: String = DateHelpers.monthString()

    let syncEngine: SyncEngine
    let shareManager: ShareManager

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)

            // Sync status indicator at bottom of sidebar
            Spacer()
            HStack(spacing: 6) {
                syncStatusDot
                Text(syncStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } detail: {
            switch selectedItem {
            case .dashboard:
                DashboardView(selectedMonth: $selectedMonth)
            case .transactions:
                TransactionsListView(selectedMonth: $selectedMonth)
            case .importStatements:
                ImportView(selectedMonth: $selectedMonth)
            case .categories:
                CategoriesSettingsView()
            case .history:
                HistoryView(selectedMonth: $selectedMonth)
            case .sync:
                SyncSettingsView(syncEngine: syncEngine, shareManager: shareManager)
            case nil:
                Text("Select an item from the sidebar")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var syncStatusDot: some View {
        switch syncEngine.status {
        case .idle:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        case .syncing:
            ProgressView()
                .controlSize(.mini)
        case .error:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
        case .noAccount:
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)
        }
    }

    private var syncStatusLabel: String {
        switch syncEngine.status {
        case .idle: return "Synced"
        case .syncing: return "Syncing..."
        case .error: return "Sync error"
        case .noAccount: return "No iCloud"
        }
    }
}
