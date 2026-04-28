import SwiftUI

/// Sheet that scans the active transactions for duplicates and lets the
/// user soft-delete the redundant rows. The most recent removal batch's
/// IDs are persisted in UserDefaults so the user can undo the bulk
/// removal even after closing and re-opening the sheet (or the app).
struct DuplicateScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isEditingLocked") private var isEditingLocked = true

    @State private var groups: [DuplicateDetector.Group] = []
    @State private var summary: DuplicateDetector.Summary?
    @State private var isScanning = false
    @State private var isRemoving = false
    @State private var isRestoring = false
    @State private var lastRemovedCount: Int?
    @State private var lastRestoredCount: Int?
    @State private var errorMessage: String?
    /// IDs available for restoration. Mirrors UserDefaults; refreshed at
    /// each rescan so the button state reflects what's actually undoable.
    @State private var restorableIds: [UUID] = []

    private static let restorableIdsKey = "DuplicateScanner_LastRemovedIds"

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            content

            Divider()

            footer
                .padding()
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            loadRestorableIds()
            rescan()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Find Duplicates")
                    .font(.title2.weight(.semibold))
                if let summary {
                    Text(summaryLine(summary))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scanning transactions…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Rescan", action: rescan)
                .disabled(isScanning || isRemoving || isRestoring)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack {
                Spacer()
                ProgressView()
                Text("Scanning…").foregroundStyle(.secondary).padding(.top, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary, summary.groupCount == 0 {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("No duplicates found")
                    .font(.headline)
                if let removed = lastRemovedCount, removed > 0 {
                    Text("Removed \(removed) duplicate transaction\(removed == 1 ? "" : "s") on the last pass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let restored = lastRestoredCount, restored > 0 {
                    Text("Restored \(restored) previously-removed transaction\(restored == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        groupRow(group)
                    }
                }
                .padding()
            }
        }
    }

    private func groupRow(_ group: DuplicateDetector.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(DateHelpers.shortDate(group.date))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)

                Text(group.normalizedDescription)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(CurrencyFormatter.format(group.amount))
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(group.amount < 0 ? Color.primary : Color.green)

                Text("× \(group.transactions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(group.transactions) { txn in
                    HStack(spacing: 6) {
                        Image(systemName: txn.id == group.keeperId ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(txn.id == group.keeperId ? Color.green : Color.red)
                            .font(.caption)
                        Text(txn.id == group.keeperId ? "Keep:" : "Remove:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(txn.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if txn.externalId != nil {
                            Text("(Plaid)")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .padding(.leading, 8)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            if isEditingLocked {
                Label("Editing is locked", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if !restorableIds.isEmpty {
                Button(action: restoreLast) {
                    if isRestoring {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Restoring…")
                        }
                    } else {
                        Label("Restore \(restorableIds.count)", systemImage: "arrow.uturn.backward")
                    }
                }
                .disabled(isRemoving || isRestoring || isScanning || isEditingLocked)
                .help(isEditingLocked
                      ? "Unlock editing to restore previously-removed duplicates"
                      : "Restore the \(restorableIds.count) duplicate\(restorableIds.count == 1 ? "" : "s") removed on the last pass")
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)

            if let summary, summary.groupCount > 0 {
                Button(role: .destructive, action: removeAll) {
                    if isRemoving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Removing…")
                        }
                    } else {
                        Text("Remove \(summary.duplicateRowCount) Duplicate\(summary.duplicateRowCount == 1 ? "" : "s")")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRemoving || isScanning || isRestoring || isEditingLocked)
                .help(isEditingLocked
                      ? "Unlock editing to remove duplicates"
                      : "Soft-delete the duplicate rows (reversible via Restore)")
            }
        }
    }

    // MARK: - Helpers

    private func summaryLine(_ summary: DuplicateDetector.Summary) -> String {
        if summary.groupCount == 0 {
            return "No duplicates."
        }
        return "\(summary.groupCount) group\(summary.groupCount == 1 ? "" : "s") · \(summary.duplicateRowCount) row\(summary.duplicateRowCount == 1 ? "" : "s") to remove · \(CurrencyFormatter.format(summary.dollarOvercount)) over-counted"
    }

    private func rescan() {
        isScanning = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let txns = try DatabaseManager.shared.fetchAllActiveTransactions()
                let found = DuplicateDetector.findDuplicates(in: txns)
                let stats = DuplicateDetector.summarize(found)
                DispatchQueue.main.async {
                    groups = found
                    summary = stats
                    isScanning = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isScanning = false
                }
            }
        }
    }

    private func removeAll() {
        let removableIds = groups.flatMap { $0.removableTransactions.map { $0.id } }
        guard !removableIds.isEmpty else { return }
        isRemoving = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let removed = try DatabaseManager.shared.softDeleteTransactions(ids: removableIds)
                DispatchQueue.main.async {
                    lastRemovedCount = removed
                    lastRestoredCount = nil
                    saveRestorableIds(removableIds)
                    isRemoving = false
                    rescan()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isRemoving = false
                }
            }
        }
    }

    private func restoreLast() {
        let ids = restorableIds
        guard !ids.isEmpty else { return }
        isRestoring = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let restored = try DatabaseManager.shared.restoreSoftDeletedTransactions(ids: ids)
                DispatchQueue.main.async {
                    lastRestoredCount = restored
                    lastRemovedCount = nil
                    clearRestorableIds()
                    isRestoring = false
                    rescan()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isRestoring = false
                }
            }
        }
    }

    // MARK: - Restorable-IDs persistence

    private func loadRestorableIds() {
        if let data = UserDefaults.standard.data(forKey: Self.restorableIdsKey),
           let strings = try? JSONDecoder().decode([String].self, from: data) {
            restorableIds = strings.compactMap(UUID.init(uuidString:))
        } else {
            restorableIds = []
        }
    }

    private func saveRestorableIds(_ ids: [UUID]) {
        let strings = ids.map { $0.uuidString }
        if let data = try? JSONEncoder().encode(strings) {
            UserDefaults.standard.set(data, forKey: Self.restorableIdsKey)
            restorableIds = ids
        }
    }

    private func clearRestorableIds() {
        UserDefaults.standard.removeObject(forKey: Self.restorableIdsKey)
        restorableIds = []
    }
}
