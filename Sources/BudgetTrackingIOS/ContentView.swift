import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }

            BudgetView()
                .tabItem { Label("Budget", systemImage: "folder.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
