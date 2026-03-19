import SwiftUI

@main
struct BudgetTrackingApp: App {
    init() {
        // Initialize database on launch
        _ = DatabaseManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 750)
    }
}
