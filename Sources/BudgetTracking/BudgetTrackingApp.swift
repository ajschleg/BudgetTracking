import SwiftUI
import AppKit

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
    @State private var ebayAuthManager = EbayAuthManager()
    @State private var plaidManager: PlaidSyncManager

    init() {
        // Make `.help(...)` tooltips appear after ~250ms instead of the
        // ~1s system default. Registering against the registration domain
        // means we don't overwrite a user's NSGlobalDomain setting if
        // they've configured their own preference.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 250
        ])

        _ = DatabaseManager.shared
        // Seed defaults only when the server store has nothing for us:
        // ServerRecordSync pulls the canonical set on devices that join
        // later, and seedDefaultsIfNeeded is name-idempotent besides.
        DatabaseManager.shared.seedDefaultsIfNeeded()
        _plaidManager = State(initialValue: PlaidSyncManager())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(ebayAuthManager: ebayAuthManager, plaidManager: plaidManager)
                .task {
                    // Converge the metadata record types (categories, rules,
                    // snapshots, profiles, files) with the server store on
                    // launch. First run after the migration seeds pull-first.
                    // Never under XCTest: the test HOST app must not push the
                    // real DB at the real server mid-suite (it did, once).
                    guard NSClassFromString("XCTestCase") == nil else { return }
                    await ServerRecordSync.shared.syncIfNeeded()
                }
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
    }
}
