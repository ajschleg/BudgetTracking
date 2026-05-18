import SwiftUI
import UIKit
import LinkKit

/// iOS Plaid Link presenter. Drives the LinkKit SDK against a
/// link_token that the Mac peer issued via the LAN RPC channel, then
/// hands the resulting public_token back to the Mac for exchange.
/// The actual PlaidAccount + initial transaction rows arrive on this
/// iPhone via the regular LAN record-sync push that fires after the
/// Mac's /api/link/exchange call completes, so there is nothing to
/// poll for on this side.
///
/// OAuth banks (Chase, Capital One, etc.) currently fall back to the
/// server-side redirect_uri + custom-scheme bounce. The page at
/// ajschleg.github.io/BudgetTracking/oauth.html shows the user a
/// "Return to BudgetTracking" link that invokes budgettracking://;
/// universal-link handling is a follow-up.
struct PlaidLinkSheet: View {
    let lanPlaidClient: LANPlaidClient
    // Fully qualified to avoid LinkKit's own `Environment` enum
    // (sandbox/production) shadowing SwiftUI's property wrapper.
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .preparing
    @State private var handler: Handler?

    enum Phase: Equatable {
        case preparing            // requesting link_token over LAN
        case linkPresenting       // LinkKit modal is up
        case exchanging(String)   // institution name shown in caption
        case succeeded(String)    // institution name shown in body
        case failed(String)       // user-facing error message
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch phase {
                case .preparing:
                    ProgressView("Connecting to your Mac…")
                        .padding(.top, 40)
                    Text("Asking BudgetTracking on your Mac for a Plaid link token.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                case .linkPresenting:
                    // LinkKit drives the UI from here; show a quiet
                    // background so the sheet doesn't flash empty when
                    // LinkKit modally takes over.
                    Color.clear

                case .exchanging(let institution):
                    ProgressView("Connecting \(institution)…")
                        .padding(.top, 40)
                    Text("Your Mac is saving this bank and pulling its first batch of transactions. They'll appear on this iPhone shortly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                case .succeeded(let institution):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("Connected \(institution)")
                        .font(.headline)
                    Text("Transactions will sync to this iPhone over LAN as soon as your Mac finishes the initial pull.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)

                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Try again") {
                        phase = .preparing
                        Task { await start() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .navigationTitle("Link bank account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await start() }
        }
    }

    // MARK: - Link flow

    @MainActor
    private func start() async {
        do {
            let token = try await lanPlaidClient.createLinkToken()
            presentLinkKit(with: token)
        } catch let error as LANPlaidRPCError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func presentLinkKit(with linkToken: String) {
        var configuration = LinkTokenConfiguration(token: linkToken) { success in
            handleLinkSuccess(success)
        }
        configuration.onExit = { exit in
            handleLinkExit(exit)
        }

        let result = Plaid.create(configuration)
        switch result {
        case .success(let linkHandler):
            // Must retain the handler until Plaid Link finishes,
            // otherwise OAuth bank flows drop on the way back to the
            // app. @State holds the strong reference.
            handler = linkHandler
            phase = .linkPresenting
            // LinkKit's PresentationMethod has no `.default` case on
            // iOS - we pick the topmost view controller in the key
            // window and present from there so Plaid Link layers on
            // top of this sheet rather than racing with it.
            if let topVC = Self.topViewController() {
                linkHandler.open(presentUsing: .viewController(topVC))
            } else {
                phase = .failed("Couldn't present Plaid Link (no active window). Try closing this sheet and reopening.")
            }
        case .failure(let error):
            phase = .failed("Plaid Link couldn't start: \(error.localizedDescription)")
        }
    }

    /// Walks the key UIWindowScene to the topmost presented view
    /// controller. Plaid Link must be presented from a UIViewController
    /// that is currently in the window hierarchy; the SwiftUI sheet
    /// hosting this view satisfies that requirement.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        guard let root = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    @MainActor
    private func handleLinkSuccess(_ success: LinkSuccess) {
        let institution = success.metadata.institution
        phase = .exchanging(institution.name)
        Task { @MainActor in
            do {
                _ = try await lanPlaidClient.exchangePublicToken(
                    publicToken: success.publicToken,
                    institutionId: institution.id,
                    institutionName: institution.name
                )
                phase = .succeeded(institution.name)
            } catch let error as LANPlaidRPCError {
                phase = .failed(error.localizedDescription)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func handleLinkExit(_ exit: LinkExit) {
        if let error = exit.error {
            // displayMessage is Plaid's user-facing copy; errorMessage
            // is the developer-facing version. Prefer displayMessage
            // when present so we don't leak internal codes.
            phase = .failed(error.displayMessage ?? error.errorMessage)
        } else {
            // Clean user exit (tapped Cancel inside Link). Close the
            // whole sheet so they're back where they started.
            dismiss()
        }
    }
}
