import SwiftUI
import AppKit
import CloudKit

@main
struct BudgetTrackingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var syncEngine: SyncEngine
    @State private var shareManager: ShareManager

    init() {
        _ = DatabaseManager.shared
        let engine = SyncEngine()
        let share = ShareManager()
        _syncEngine = State(initialValue: engine)
        _shareManager = State(initialValue: share)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(syncEngine: syncEngine, shareManager: shareManager)
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            TextEditingCommands()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Register for remote notifications (CloudKit push)
        NSApp.registerForRemoteNotifications()
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // CloudKit handles this internally
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Failed to register for remote notifications: \(error)")
    }

    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        // Handle accepting a share invitation
        let container = CKContainer(identifier: SyncConstants.containerIdentifier)
        Task {
            try? await container.accept(metadata)
        }
    }
}
