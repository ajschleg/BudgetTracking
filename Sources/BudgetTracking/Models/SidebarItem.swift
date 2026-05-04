import Foundation

/// Identifies a top-level page in the macOS sidebar.
/// Also used by InsightsViewModel as a key for per-page chat state, which
/// is why this lives outside the macOS-only ContentView and ships to iOS.
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
