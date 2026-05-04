import SwiftUI
import CloudKit
import UIKit

@main
struct BudgetTrackingIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var syncEngine: SyncEngine

    init() {
        _ = DatabaseManager.shared
        _syncEngine = State(initialValue: SyncEngine())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(syncEngine: syncEngine)
        }
    }
}

/// iOS counterpart to the macOS AppDelegate. Registers for remote
/// notifications so CKSyncEngine receives CloudKit pushes and can keep
/// the local DB in sync with the user's other signed-in devices.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // CloudKit handles delivery internally; nothing to do here.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Failed to register for remote notifications: \(error)")
    }

    /// Accept a CloudKit share invite. Mirrors the macOS AppDelegate so
    /// future "share my budget with my partner" flows work on iPhone too.
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        let container = CKContainer(identifier: SyncConstants.containerIdentifier)
        Task {
            try? await container.accept(metadata)
        }
    }
}
