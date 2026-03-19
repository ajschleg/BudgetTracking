import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case transactions = "Transactions"
    case importStatements = "Import"
    case categories = "Categories"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .transactions: return "list.bullet.rectangle"
        case .importStatements: return "square.and.arrow.down"
        case .categories: return "folder.fill"
        case .history: return "clock.fill"
        }
    }
}

struct ContentView: View {
    @State private var selectedItem: SidebarItem? = .dashboard
    @State private var selectedMonth: String = DateHelpers.monthString()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)
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
            case nil:
                Text("Select an item from the sidebar")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
