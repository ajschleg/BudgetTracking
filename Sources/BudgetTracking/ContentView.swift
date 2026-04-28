import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case income = "Income"
    case transactions = "Transactions"
    case categories = "Categories"
    case accounts = "Accounts"
    case imports = "Imports"
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
        case .accounts: return "building.columns.fill"
        case .imports: return "square.and.arrow.down"
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
    @AppStorage("isEditingLocked") private var isEditingLocked = true

    let syncEngine: SyncEngine
    let shareManager: ShareManager
    let lanSyncEngine: LANSyncEngine
    let ebayAuthManager: EbayAuthManager
    @Bindable var plaidManager: PlaidSyncManager

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
            VStack(spacing: 0) {
                // Global banner for any Plaid item needing update mode.
                // Auto-hides when LOGIN_REPAIRED or successful reconnect
                // clears the needs_update flag on the server.
                PlaidUpdateBanner(plaidManager: plaidManager)

                switch selectedItem {
                case .dashboard:
                    DashboardView(selectedMonth: $selectedMonth, selectedItem: $selectedItem, aiViewModel: insightsViewModel)
                case .income:
                    IncomeTabView(selectedMonth: $selectedMonth, aiViewModel: insightsViewModel, ebayAuthManager: ebayAuthManager)
                case .transactions:
                    TransactionsListView(selectedMonth: $selectedMonth, aiViewModel: insightsViewModel)
                case .accounts:
                    AccountsView(
                        aiViewModel: insightsViewModel,
                        plaidManager: plaidManager
                    )
                case .imports:
                    ImportView(selectedMonth: $selectedMonth, aiViewModel: insightsViewModel)
                case .categories:
                    CategoriesSettingsView(aiViewModel: insightsViewModel)
                case .history:
                    HistoryView(selectedMonth: $selectedMonth, aiViewModel: insightsViewModel)
                case .insights:
                    InsightsView(selectedMonth: $selectedMonth, viewModel: insightsViewModel)
                case .sync:
                    SyncSettingsView(syncEngine: syncEngine, shareManager: shareManager, lanSyncEngine: lanSyncEngine)
                case .settings:
                    SettingsView(aiViewModel: insightsViewModel, ebayAuthManager: ebayAuthManager, plaidManager: plaidManager)
                case nil:
                    Text("Select an item from the sidebar")
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.snappy, value: plaidManager.itemsNeedingUpdate.map(\.id))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isEditingLocked.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isEditingLocked ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(isEditingLocked ? .orange : .green)
                        Text(isEditingLocked ? "Locked" : "Unlocked")
                    }
                }
                .help(isEditingLocked
                      ? "Editing is locked — click to unlock and allow changes to budgets, categories, and transaction assignments"
                      : "Editing is unlocked — click to lock and prevent accidental changes")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    lanSyncEngine.syncNow()
                } label: {
                    HStack(spacing: 4) {
                        lanSyncToolbarIcon
                        if case .syncing(let name) = lanSyncEngine.status {
                            Text("Syncing with \(name)…")
                                .font(.caption)
                        } else {
                            Text("Sync")
                        }
                    }
                }
                .disabled(lanSyncEngine.connectedPeerName == nil)
                .help(lanSyncToolbarHelp)
            }
        }
        // Plaid OAuth completion sheet — presented when app receives OAuth redirect
        .sheet(isPresented: Binding(
            get: { plaidManager.pendingOAuthRedirectURI != nil },
            set: { if !$0 { plaidManager.pendingOAuthRedirectURI = nil } }
        )) {
            PlaidLinkView(
                plaidManager: plaidManager,
                oauthRedirectURI: plaidManager.pendingOAuthRedirectURI
            )
        }
        // Plaid update-mode sheet — presented when user clicks Reconnect
        // on an item whose needs_update flag is set.
        .sheet(isPresented: Binding(
            get: { plaidManager.pendingUpdateItemId != nil },
            set: { if !$0 { plaidManager.finishUpdateMode() } }
        )) {
            PlaidLinkView(
                plaidManager: plaidManager,
                updateItemId: plaidManager.pendingUpdateItemId,
                updateAccountSelection: plaidManager.pendingUpdateAccountSelection
            )
        }
        .task {
            // On launch, ask the server whether any items have pending
            // webhook-delivered updates. If yes, auto-sync so the user
            // sees fresh transactions without touching Settings.
            await plaidManager.checkTransactionsStatus(autoSyncIfPending: true)

            // Then keep the update-mode banner in sync with server
            // state while the app is open. Plaid may clear a flag via
            // LOGIN_REPAIRED webhook while the app is running — polling
            // here makes the banner disappear within 30s without
            // requiring the user to restart. Cheap read-only call.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await plaidManager.refreshUpdateModeStatus()
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
        if let peer = lanSyncEngine.connectedPeerName {
            return "Sync transactions, categories, and budgets now with \(peer)"
        }
        switch lanSyncEngine.status {
        case .disabled:
            return "LAN sync is disabled — enable it in Sync settings to share data with another Mac on this network"
        case .searching:
            return "Searching for another Mac on this network running BudgetTracking…"
        default:
            return "No peer connected — open this app on another Mac on the same network to enable LAN sync"
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
