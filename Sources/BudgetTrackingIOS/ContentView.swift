import SwiftUI

struct ContentView: View {
    let syncEngine: SyncEngine
    let lanSyncEngine: LANSyncEngine

    var body: some View {
        TabView {
            DashboardView(syncEngine: syncEngine, lanSyncEngine: lanSyncEngine)
                .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }

            BudgetView()
                .tabItem { Label("Budget", systemImage: "folder.fill") }

            SettingsView(syncEngine: syncEngine, lanSyncEngine: lanSyncEngine)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
