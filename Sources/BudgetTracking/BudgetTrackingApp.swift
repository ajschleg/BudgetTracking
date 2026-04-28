import SwiftUI
import AppKit
import CloudKit

/// Pure routing decision for an incoming budgettracking:// URL. The
/// App's onOpenURL handler maps over this enum to dispatch the side
/// effects, but the host-validation logic lives here so it can be
/// unit-tested without standing up SwiftUI scenes. A scheme other
/// than budgettracking, or a host the app does not recognize, must
/// always resolve to .ignore — see SECURITY_POLICY §7.
enum AppURLRoute: Equatable {
    case ignore
    case plaidOAuth(redirectURI: String)
    case plaidOAuthSuccess(URL)
    case ebay(URL)

    static func route(_ url: URL) -> AppURLRoute {
        guard url.scheme == "budgettracking" else { return .ignore }
        guard let host = url.host else { return .ignore }

        switch host {
        case "plaid-oauth":
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
                !redirectURI.isEmpty
            else { return .ignore }
            return .plaidOAuth(redirectURI: redirectURI)
        case "plaid-oauth-success":
            return .plaidOAuthSuccess(url)
        case "ebay":
            return .ebay(url)
        default:
            return .ignore
        }
    }
}

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
                    switch AppURLRoute.route(url) {
                    case .ignore:
                        return
                    case .plaidOAuth(let redirectURI):
                        plaidManager.pendingOAuthRedirectURI = redirectURI
                    case .plaidOAuthSuccess(let url):
                        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                        let items = components.queryItems ?? []
                        let itemId = items.first(where: { $0.name == "item_id" })?.value ?? ""
                        let institution = items.first(where: { $0.name == "institution" })?.value ?? "Unknown"
                        if let accountsJSON = items.first(where: { $0.name == "accounts" })?.value,
                           let data = accountsJSON.data(using: .utf8),
                           let accounts = try? JSONDecoder().decode([PlaidService.AccountResponse].self, from: data) {
                            plaidManager.handleLinkSuccess(itemId: itemId, institution: institution, accounts: accounts)
                        }
                    case .ebay(let url):
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
