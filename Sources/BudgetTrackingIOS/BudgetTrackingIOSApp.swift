import SwiftUI

@main
struct BudgetTrackingIOSApp: App {
    init() {
        _ = DatabaseManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
