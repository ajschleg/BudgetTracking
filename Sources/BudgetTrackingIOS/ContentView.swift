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

            ComingSoonView(title: "Settings")
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

private struct ComingSoonView: View {
    let title: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("\(title) — Coming soon")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}
