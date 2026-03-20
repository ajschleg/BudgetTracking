import SwiftUI
import CloudKit

struct SyncSettingsView: View {
    @State private var syncEngine: SyncEngine
    @State private var shareManager: ShareManager
    @State private var lanSyncEngine: LANSyncEngine
    @State private var inviteEmail = ""
    @State private var isInviting = false
    @State private var inviteError: String?
    @State private var inviteSuccess = false
    @State private var showDiagnostics = false
    @State private var diagnosticInfo: DiagnosticInfo?
    @State private var isLoadingDiagnostics = false

    struct DiagnosticInfo {
        var iCloudAccount: String = "Checking..."
        var containerID: String = SyncConstants.containerIdentifier
        var privateZones: [String] = []
        var sharedZones: [String] = []
        var shareExists: Bool = false
        var shareURL: String?
        var participantDetails: [(email: String, status: String, permission: String)] = []
        var localRecordCounts: [String: Int] = [:]
        var cloudRecordCounts: [String: Int] = [:]
        var pendingChanges: Int = 0
        var errors: [String] = []
    }

    init(syncEngine: SyncEngine, shareManager: ShareManager, lanSyncEngine: LANSyncEngine) {
        _syncEngine = State(initialValue: syncEngine)
        _shareManager = State(initialValue: shareManager)
        _lanSyncEngine = State(initialValue: lanSyncEngine)
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

                        HStack(spacing: 4) {
                            Image(systemName: syncEngine.isParticipant ? "person.2.fill" : "person.fill")
                                .foregroundStyle(syncEngine.isParticipant ? .blue : .green)
                            Text(syncEngine.isParticipant ? "Participant — using shared budget" : "Owner — using your budget")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                                Text("Enter their iCloud email address:")
                                    .font(.callout)

                                HStack {
                                    TextField("spouse@icloud.com", text: $inviteEmail)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 300)

                                    Button {
                                        Task { await inviteByEmail() }
                                    } label: {
                                        if isInviting {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label("Invite", systemImage: "person.badge.plus")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(inviteEmail.isEmpty || isInviting)
                                }

                                if let inviteError {
                                    Text(inviteError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }

                        case .sharing:
                            ProgressView("Setting up sharing...")

                        case .shared(let count):
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(count) participant\(count == 1 ? "" : "s") connected")
                                    .font(.callout)

                                if !shareManager.participantNames.isEmpty {
                                    ForEach(shareManager.participantNames, id: \.self) { name in
                                        HStack {
                                            Image(systemName: "person.circle.fill")
                                                .foregroundStyle(.green)
                                            Text(name)
                                                .font(.callout)
                                        }
                                    }
                                }

                                Divider()

                                Text("Add another person:")
                                    .font(.callout)

                                HStack {
                                    TextField("email@icloud.com", text: $inviteEmail)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 300)

                                    Button {
                                        Task { await inviteByEmail() }
                                    } label: {
                                        if isInviting {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label("Invite", systemImage: "person.badge.plus")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(inviteEmail.isEmpty || isInviting)
                                }

                                if inviteSuccess {
                                    Text("Invitation sent!")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }

                                if let inviteError {
                                    Text(inviteError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

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
                                shareManager.resetStatus()
                            } label: {
                                Label("Try Again", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Sharing", systemImage: "person.2")
                }

                // Local Network Sync Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            lanSyncStatusIcon
                            VStack(alignment: .leading) {
                                Text("Local Network Sync")
                                    .font(.headline)
                                lanSyncStatusText
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { lanSyncEngine.isEnabled },
                                set: { lanSyncEngine.isEnabled = $0 }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }

                        if lanSyncEngine.isEnabled {
                            Divider()

                            if lanSyncEngine.discoveredPeers.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Searching for devices on your network...")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Nearby Devices")
                                    .font(.callout)
                                    .fontWeight(.medium)

                                ForEach(lanSyncEngine.discoveredPeers) { peer in
                                    HStack {
                                        Image(systemName: "desktopcomputer")
                                            .foregroundStyle(.blue)
                                        Text(peer.name)
                                            .font(.callout)
                                        Spacer()
                                        if lanSyncEngine.connectedPeerName == peer.name {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                            Text("Connected")
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            }

                            if lanSyncEngine.connectedPeerName != nil {
                                HStack {
                                    Button {
                                        lanSyncEngine.syncNow()
                                    } label: {
                                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .buttonStyle(.bordered)

                                    if let lastSync = lanSyncEngine.lastLANSyncDate {
                                        Text("Last synced: \(lastSync.formatted(.relative(presentation: .named)))")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Local Network", systemImage: "wifi")
                }

                // Info Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How it works")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            infoRow(icon: "icloud", text: "iCloud: Syncs automatically when signed in")
                            infoRow(icon: "wifi", text: "LAN: Syncs with devices on the same WiFi network")
                            infoRow(icon: "person.2", text: "Share with your spouse to co-manage your budget")
                            infoRow(icon: "lock.shield", text: "Data is encrypted and stored in your private iCloud")
                            infoRow(icon: "desktopcomputer", text: "LAN sync works without iCloud — great for cross-region accounts")
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Info", systemImage: "info.circle")
                }

                // Diagnostics Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Diagnostics")
                                .font(.headline)
                            Spacer()
                            Button {
                                if showDiagnostics && diagnosticInfo == nil {
                                    Task { await loadDiagnostics() }
                                }
                                withAnimation { showDiagnostics.toggle() }
                            } label: {
                                Label(
                                    showDiagnostics ? "Hide" : "Show",
                                    systemImage: showDiagnostics ? "chevron.up" : "chevron.down"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }

                        if showDiagnostics {
                            if isLoadingDiagnostics {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading diagnostics...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let info = diagnosticInfo {
                                diagnosticContent(info)
                            }

                            HStack {
                                Button {
                                    Task { await loadDiagnostics() }
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .disabled(isLoadingDiagnostics)

                                Button {
                                    copyDiagnosticsToClipboard()
                                } label: {
                                    Label("Copy to Clipboard", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .disabled(diagnosticInfo == nil)
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
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

    // MARK: - LAN Sync Status Helpers

    @ViewBuilder
    private var lanSyncStatusIcon: some View {
        switch lanSyncEngine.status {
        case .disabled:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.title2)
        case .searching:
            Image(systemName: "wifi")
                .foregroundStyle(.orange)
                .font(.title2)
        case .connected:
            Image(systemName: "wifi")
                .foregroundStyle(.green)
                .font(.title2)
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.red)
                .font(.title2)
        }
    }

    @ViewBuilder
    private var lanSyncStatusText: some View {
        switch lanSyncEngine.status {
        case .disabled:
            Text("Disabled — turn on to sync with nearby devices")
        case .searching:
            Text("Searching for devices...")
        case .connected(let name):
            Text("Connected to \(name)")
        case .syncing(let name):
            Text("Syncing with \(name)...")
        case .error(let msg):
            Text("Error: \(msg)")
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

    // MARK: - Diagnostics Content

    @ViewBuilder
    private func diagnosticContent(_ info: DiagnosticInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // iCloud Account
            diagnosticSection("iCloud Account") {
                diagnosticRow("Status", info.iCloudAccount)
                diagnosticRow("Container", info.containerID)
                diagnosticRow("Role", syncEngine.isParticipant ? "Participant" : "Owner")
            }

            // Zones
            diagnosticSection("CloudKit Zones") {
                diagnosticRow("Private Zones", info.privateZones.isEmpty ? "None" : info.privateZones.joined(separator: ", "))
                diagnosticRow("Shared Zones", info.sharedZones.isEmpty ? "None" : info.sharedZones.joined(separator: ", "))
            }

            // Share
            diagnosticSection("Share") {
                diagnosticRow("Share Exists", info.shareExists ? "Yes" : "No")
                if let url = info.shareURL {
                    diagnosticRow("Share URL", url)
                }
                if !info.participantDetails.isEmpty {
                    ForEach(Array(info.participantDetails.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .top) {
                            Text("  \(p.email)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(p.status)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(p.status == "accepted" ? .green : .orange)
                                Text(p.permission)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    diagnosticRow("Participants", "None")
                }
            }

            // Local DB Record Counts
            diagnosticSection("Local Database") {
                ForEach(info.localRecordCounts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    diagnosticRow(key, "\(value)")
                }
                diagnosticRow("Pending Changes", "\(info.pendingChanges)")
            }

            // Cloud Record Counts
            if !info.cloudRecordCounts.isEmpty {
                diagnosticSection("CloudKit Records") {
                    ForEach(info.cloudRecordCounts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        diagnosticRow(key, "\(value)")
                    }
                }
            }

            // Errors
            if !info.errors.isEmpty {
                diagnosticSection("Errors") {
                    ForEach(info.errors, id: \.self) { error in
                        Text(error)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Load Diagnostics

    private func loadDiagnostics() async {
        isLoadingDiagnostics = true
        var info = DiagnosticInfo()

        let container = CKContainer(identifier: SyncConstants.containerIdentifier)

        // 1. Check iCloud account
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                info.iCloudAccount = "Available"
            case .noAccount:
                info.iCloudAccount = "No Account"
            case .restricted:
                info.iCloudAccount = "Restricted"
            case .couldNotDetermine:
                info.iCloudAccount = "Could Not Determine"
            case .temporarilyUnavailable:
                info.iCloudAccount = "Temporarily Unavailable"
            @unknown default:
                info.iCloudAccount = "Unknown (\(accountStatus.rawValue))"
            }
        } catch {
            info.iCloudAccount = "Error: \(error.localizedDescription)"
            info.errors.append("Account check: \(error.localizedDescription)")
        }

        // 2. List zones
        do {
            let privateZones = try await container.privateCloudDatabase.allRecordZones()
            info.privateZones = privateZones.map { $0.zoneID.zoneName }
        } catch {
            info.errors.append("Private zones: \(error.localizedDescription)")
        }

        do {
            let sharedZones = try await container.sharedCloudDatabase.allRecordZones()
            info.sharedZones = sharedZones.map { "\($0.zoneID.zoneName) (owner: \($0.zoneID.ownerName))" }
        } catch {
            info.errors.append("Shared zones: \(error.localizedDescription)")
        }

        // 3. Check share
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
            if let budgetZone = zones.first(where: { $0.zoneID.zoneName == SyncConstants.zoneName }) {
                if let shareRef = budgetZone.share {
                    let shareRecord = try await container.privateCloudDatabase.record(for: shareRef.recordID)
                    if let ckShare = shareRecord as? CKShare {
                        info.shareExists = true
                        info.shareURL = ckShare.url?.absoluteString

                        for participant in ckShare.participants {
                            let email = participant.userIdentity.lookupInfo?.emailAddress
                                ?? participant.userIdentity.nameComponents.flatMap {
                                    PersonNameComponentsFormatter().string(from: $0)
                                }
                                ?? "Unknown"

                            let status: String
                            switch participant.acceptanceStatus {
                            case .accepted: status = "accepted"
                            case .pending: status = "pending"
                            case .removed: status = "removed"
                            case .unknown: status = "unknown"
                            @unknown default: status = "unknown"
                            }

                            let permission: String
                            switch participant.permission {
                            case .readWrite: permission = "read-write"
                            case .readOnly: permission = "read-only"
                            case .none: permission = "none"
                            @unknown default: permission = "unknown"
                            }

                            let role: String
                            switch participant.role {
                            case .owner: role = " (owner)"
                            case .privateUser: role = " (private)"
                            case .publicUser: role = " (public)"
                            case .unknown: role = ""
                            @unknown default: role = ""
                            }

                            info.participantDetails.append((
                                email: "\(email)\(role)",
                                status: status,
                                permission: permission
                            ))
                        }
                    }
                }
            }
        } catch {
            info.errors.append("Share check: \(error.localizedDescription)")
        }

        // 4. Local DB counts
        do {
            let dbQueue = DatabaseManager.shared.dbQueue
            let categoriesCount = try await dbQueue.read { db in
                try BudgetCategory.filter(sql: "isDeleted = 0").fetchCount(db)
            }
            let transactionsCount = try await dbQueue.read { db in
                try Transaction.filter(sql: "isDeleted = 0").fetchCount(db)
            }
            let filesCount = try await dbQueue.read { db in
                try ImportedFile.filter(sql: "isDeleted = 0").fetchCount(db)
            }
            let rulesCount = try await dbQueue.read { db in
                try CategorizationRule.filter(sql: "isDeleted = 0").fetchCount(db)
            }
            let snapshotsCount = try await dbQueue.read { db in
                try MonthlySnapshot.filter(sql: "isDeleted = 0").fetchCount(db)
            }
            info.localRecordCounts["Categories"] = categoriesCount
            info.localRecordCounts["Transactions"] = transactionsCount
            info.localRecordCounts["Imported Files"] = filesCount
            info.localRecordCounts["Rules"] = rulesCount
            info.localRecordCounts["Snapshots"] = snapshotsCount

            // Pending (has cloudKitRecordName == nil, meaning never synced)
            let unsyncedCategories = try await dbQueue.read { db in
                try BudgetCategory.filter(sql: "cloudKitRecordName IS NULL AND isDeleted = 0").fetchCount(db)
            }
            let unsyncedTransactions = try await dbQueue.read { db in
                try Transaction.filter(sql: "cloudKitRecordName IS NULL AND isDeleted = 0").fetchCount(db)
            }
            let unsyncedFiles = try await dbQueue.read { db in
                try ImportedFile.filter(sql: "cloudKitRecordName IS NULL AND isDeleted = 0").fetchCount(db)
            }
            let unsyncedRules = try await dbQueue.read { db in
                try CategorizationRule.filter(sql: "cloudKitRecordName IS NULL AND isDeleted = 0").fetchCount(db)
            }
            info.pendingChanges = unsyncedCategories + unsyncedTransactions + unsyncedFiles + unsyncedRules
        } catch {
            info.errors.append("Local DB: \(error.localizedDescription)")
        }

        // 5. Cloud record counts (query each type)
        let recordTypes = [
            SyncConstants.RecordType.budgetCategory,
            SyncConstants.RecordType.transaction,
            SyncConstants.RecordType.importedFile,
            SyncConstants.RecordType.categorizationRule,
            SyncConstants.RecordType.monthlySnapshot,
        ]

        for recordType in recordTypes {
            do {
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let (results, _) = try await container.privateCloudDatabase.records(
                    matching: query,
                    inZoneWith: SyncConstants.zoneID,
                    resultsLimit: CKQueryOperation.maximumResults
                )
                info.cloudRecordCounts[recordType] = results.count
            } catch {
                info.cloudRecordCounts[recordType] = -1
                info.errors.append("Cloud query \(recordType): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            diagnosticInfo = info
            isLoadingDiagnostics = false
        }
    }

    // MARK: - Copy to Clipboard

    private func copyDiagnosticsToClipboard() {
        guard let info = diagnosticInfo else { return }
        var text = "=== BudgetTracking Sync Diagnostics ===\n"
        text += "Date: \(Date().formatted())\n\n"
        text += "iCloud Account: \(info.iCloudAccount)\n"
        text += "Container: \(info.containerID)\n"
        text += "Role: \(syncEngine.isParticipant ? "Participant" : "Owner")\n\n"
        text += "Private Zones: \(info.privateZones.joined(separator: ", "))\n"
        text += "Shared Zones: \(info.sharedZones.joined(separator: ", "))\n\n"
        text += "Share Exists: \(info.shareExists)\n"
        if let url = info.shareURL { text += "Share URL: \(url)\n" }
        text += "Participants:\n"
        for p in info.participantDetails {
            text += "  \(p.email) - \(p.status) (\(p.permission))\n"
        }
        text += "\nLocal DB:\n"
        for (key, value) in info.localRecordCounts.sorted(by: { $0.key < $1.key }) {
            text += "  \(key): \(value)\n"
        }
        text += "  Pending: \(info.pendingChanges)\n"
        text += "\nCloudKit Records:\n"
        for (key, value) in info.cloudRecordCounts.sorted(by: { $0.key < $1.key }) {
            text += "  \(key): \(value == -1 ? "error" : "\(value)")\n"
        }
        if !info.errors.isEmpty {
            text += "\nErrors:\n"
            for error in info.errors {
                text += "  \(error)\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func inviteByEmail() async {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }

        isInviting = true
        inviteError = nil
        inviteSuccess = false

        do {
            try await shareManager.shareWithEmail(email)
            inviteEmail = ""
            inviteSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                inviteSuccess = false
            }
        } catch {
            inviteError = "Failed to invite: \(error.localizedDescription)"
        }

        isInviting = false
    }
}
