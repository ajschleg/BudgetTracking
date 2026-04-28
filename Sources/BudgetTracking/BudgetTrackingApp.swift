import SwiftUI
import AppKit
import CloudKit

@main
struct BudgetTrackingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var syncEngine: SyncEngine
    @State private var shareManager: ShareManager
    @State private var lanSyncEngine: LANSyncEngine
    @State private var ebayAuthManager = EbayAuthManager()
    @State private var plaidManager = PlaidSyncManager()

    init() {
        // Make `.help(...)` tooltips appear after ~250ms instead of the
        // ~1s system default. Registering against the registration domain
        // means we don't overwrite a user's NSGlobalDomain setting if
        // they've configured their own preference.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 250
        ])

        _ = DatabaseManager.shared
        let engine = SyncEngine()
        let share = ShareManager()
        let lanEngine = LANSyncEngine()
        _syncEngine = State(initialValue: engine)
        _shareManager = State(initialValue: share)
        _lanSyncEngine = State(initialValue: lanEngine)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(syncEngine: syncEngine, shareManager: shareManager, lanSyncEngine: lanSyncEngine, ebayAuthManager: ebayAuthManager, plaidManager: plaidManager)
                .onOpenURL { url in
                    guard url.scheme == "budgettracking" else { return }

                    if url.host == "plaid-oauth" {
                        // OAuth redirect from bank → bounce page → app
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value {
                            plaidManager.pendingOAuthRedirectURI = redirectURI
                        }
                    } else if url.host == "plaid-oauth-success" {
                        // Direct OAuth success (from local oauth.html opened in browser)
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                            let items = components.queryItems ?? []
                            let itemId = items.first(where: { $0.name == "item_id" })?.value ?? ""
                            let institution = items.first(where: { $0.name == "institution" })?.value ?? "Unknown"
                            if let accountsJSON = items.first(where: { $0.name == "accounts" })?.value,
                               let data = accountsJSON.data(using: .utf8),
                               let accounts = try? JSONDecoder().decode([PlaidService.AccountResponse].self, from: data) {
                                plaidManager.handleLinkSuccess(itemId: itemId, institution: institution, accounts: accounts)
                            }
                        }
                    } else if url.absoluteString.contains("ebay") {
                        ebayAuthManager.handleCallback(url: url)
                    }
                }
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
