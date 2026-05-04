import SwiftUI
import CloudKit
import UIKit

@main
struct BudgetTrackingIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var syncEngine: SyncEngine
    @State private var lanSyncEngine: LANSyncEngine

    init() {
        _ = DatabaseManager.shared

        // Default LAN sync ON for iOS so the phone discovers the Mac
        // immediately - matches the LAN-only topology the user picked.
        // The macOS app stays opt-in; this default-on only affects the
        // iOS bundle id's UserDefaults. Idempotent: a one-time flag
        // means we don't override the user later turning it off.
        let didApplyDefault = UserDefaults.standard.bool(forKey: "iOS_LANSyncDefaultApplied")
        if !didApplyDefault {
            UserDefaults.standard.set(true, forKey: "LANSync_isEnabled")
            UserDefaults.standard.set(true, forKey: "iOS_LANSyncDefaultApplied")
        }

        _syncEngine = State(initialValue: SyncEngine())
        _lanSyncEngine = State(initialValue: LANSyncEngine())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                syncEngine: syncEngine,
                lanSyncEngine: lanSyncEngine
            )
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
