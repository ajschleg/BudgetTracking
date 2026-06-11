import SwiftUI
import UIKit

@main
struct BudgetTrackingIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        _ = DatabaseManager.shared
        // No default seeding on iOS: this device mirrors the server store.
        // Categories, rules, budgets, and transactions all arrive via the
        // first pull once the server URL + token are configured in Settings.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Converge with the server store on launch (no-ops until
                    // server sync is enabled via Settings). Never under XCTest.
                    guard NSClassFromString("XCTestCase") == nil else { return }
                    await ServerRecordSync.shared.syncIfNeeded()
                    _ = await ServerTransactionSync.shared.pull()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }
}
