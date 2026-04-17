import SwiftUI

/// Global alert shown above every page when one or more linked banks
/// need the user to enter update mode (re-authenticate or renew OAuth
/// consent). Hides itself automatically once the server clears the
/// needs_update flag — either by webhook (LOGIN_REPAIRED) or after the
/// user finishes the Reconnect sheet.
struct PlaidUpdateBanner: View {
    @Bindable var plaidManager: PlaidSyncManager

    var body: some View {
        if !plaidManager.itemsNeedingUpdate.isEmpty {
            VStack(spacing: 0) {
                ForEach(plaidManager.itemsNeedingUpdate, id: \.id) { item in
                    PlaidUpdateBannerRow(
                        item: item,
                        onReconnect: { plaidManager.startUpdateMode(for: item.id) }
                    )
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct PlaidUpdateBannerRow: View {
    let item: PlaidService.ItemSummary
    let onReconnect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(0.2)))

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subhead)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            Button(action: onReconnect) {
                Text("Reconnect")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(bannerColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(bannerColor)
    }

    // MARK: - Styling by reason

    private var icon: String {
        switch item.needs_update_reason {
        case "ITEM_LOGIN_REQUIRED":
            return "exclamationmark.triangle.fill"
        case "PENDING_EXPIRATION", "PENDING_DISCONNECT":
            return "clock.badge.exclamationmark.fill"
        default:
            return "exclamationmark.circle.fill"
        }
    }

    private var bannerColor: Color {
        switch item.needs_update_reason {
        case "ITEM_LOGIN_REQUIRED":
            return .red
        case "PENDING_EXPIRATION", "PENDING_DISCONNECT":
            return .orange
        default:
            return .orange
        }
    }

    private var headline: String {
        let name = item.institution_name ?? "Your bank"
        switch item.needs_update_reason {
        case "ITEM_LOGIN_REQUIRED":
            return "\(name) needs you to sign in again"
        case "PENDING_EXPIRATION":
            return "\(name) access expires soon"
        case "PENDING_DISCONNECT":
            return "\(name) will disconnect soon"
        default:
            return "\(name) needs attention"
        }
    }

    private var subhead: String {
        switch item.needs_update_reason {
        case "ITEM_LOGIN_REQUIRED":
            return "New transactions can't sync until you reconnect."
        case "PENDING_EXPIRATION":
            return "Plaid consent expires within 7 days. Reconnect to keep syncing."
        case "PENDING_DISCONNECT":
            return "This connection will stop syncing within 7 days. Reconnect now."
        default:
            return "Tap Reconnect to restore this connection."
        }
    }
}
