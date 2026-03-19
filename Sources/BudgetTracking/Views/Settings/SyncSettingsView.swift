import SwiftUI
import CloudKit

struct SyncSettingsView: View {
    @State private var syncEngine: SyncEngine
    @State private var shareManager: ShareManager

    init(syncEngine: SyncEngine, shareManager: ShareManager) {
        _syncEngine = State(initialValue: syncEngine)
        _shareManager = State(initialValue: shareManager)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("iCloud Sync")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // Sync Status Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            syncStatusIcon
                            VStack(alignment: .leading) {
                                Text("Sync Status")
                                    .font(.headline)
                                syncStatusText
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sync Now") {
                                syncEngine.pushLocalChanges()
                            }
                            .disabled(syncEngine.status == .noAccount)
                        }

                        if let lastSync = syncEngine.lastSyncDate {
                            Text("Last synced: \(lastSync.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

                // Sharing Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            shareStatusIcon
                            VStack(alignment: .leading) {
                                Text("Sharing")
                                    .font(.headline)
                                shareStatusText
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        switch shareManager.shareStatus {
                        case .notShared:
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Share your budget with your spouse so you can both view and edit the same data.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)

                                Button {
                                    Task { await createAndPresentShare() }
                                } label: {
                                    Label("Share Budget", systemImage: "person.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                        case .sharing:
                            ProgressView("Setting up sharing...")

                        case .shared(let count):
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(count) participant\(count == 1 ? "" : "s") connected")
                                    .font(.callout)

                                Button(role: .destructive) {
                                    Task {
                                        try? await shareManager.stopSharing()
                                    }
                                } label: {
                                    Label("Stop Sharing", systemImage: "person.badge.minus")
                                }
                            }

                        case .error(let message):
                            Text("Error: \(message)")
                                .font(.callout)
                                .foregroundStyle(.red)

                            Button {
                                Task { await createAndPresentShare() }
                            } label: {
                                Label("Try Again", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Sharing", systemImage: "person.2")
                }

                // Info Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How it works")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            infoRow(icon: "arrow.up.arrow.down", text: "Changes sync automatically via iCloud")
                            infoRow(icon: "person.2", text: "Share with your spouse to co-manage your budget")
                            infoRow(icon: "lock.shield", text: "Data is encrypted and stored in your private iCloud")
                            infoRow(icon: "exclamationmark.triangle", text: "Both users need to be signed into iCloud")
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            }
            .padding(24)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var syncStatusIcon: some View {
        switch syncEngine.status {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title2)
        case .noAccount:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
                .font(.title2)
        }
    }

    @ViewBuilder
    private var syncStatusText: some View {
        switch syncEngine.status {
        case .idle:
            Text("Up to date")
        case .syncing:
            Text("Syncing...")
        case .error(let msg):
            Text("Error: \(msg)")
        case .noAccount:
            Text("No iCloud account — sign in to sync")
        }
    }

    @ViewBuilder
    private var shareStatusIcon: some View {
        switch shareManager.shareStatus {
        case .notShared:
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(.secondary)
                .font(.title2)
        case .sharing:
            ProgressView()
                .controlSize(.small)
        case .shared:
            Image(systemName: "person.2.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title2)
        }
    }

    @ViewBuilder
    private var shareStatusText: some View {
        switch shareManager.shareStatus {
        case .notShared:
            Text("Not shared")
        case .sharing:
            Text("Setting up...")
        case .shared(let count):
            Text("Shared with \(count - 1) other\(count == 2 ? "" : "s")")
        case .error:
            Text("Error")
        }
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func createAndPresentShare() async {
        do {
            let ckShare = try await shareManager.createShare()
            // On macOS, present the sharing UI via NSSharingService
            if let url = ckShare.url {
                let sharingService = NSSharingService(named: .sendViaAirDrop)
                    ?? NSSharingService(named: .composeEmail)
                if let service = sharingService {
                    service.perform(withItems: [url])
                } else {
                    // Fallback: copy URL to clipboard
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        } catch {
            // Error is handled by ShareManager
        }
    }
}
