import Foundation
import SwiftUI

/// The store-facing slice of PlaidService that ServerTransactionSync uses.
/// A separate protocol from PlaidTransactionSyncing so the existing test
/// mocks stay source-compatible; tests mock this one independently.
protocol ServerTransactionStoring {
    func fetchTransactionChanges(since: Int, limit: Int) async throws -> PlaidService.ChangesResponse
    func createTransactions(_ rows: [PlaidService.ServerTransactionUpload]) async throws -> PlaidService.CreateTransactionsResponse
    func batchPatchTransactions(_ ops: [(id: String, patch: [String: Any])]) async throws -> PlaidService.BatchPatchResponse
}

extension PlaidService: ServerTransactionStoring {}

/// Keeps the local GRDB cache converged with the server's transactions
/// store (the source of truth since the 2026-06 server-hub migration).
///
/// - pull(): page /api/transactions/changes after our cursor and fold each
///   page into the cache; the cursor persists per page so an interrupted
///   pull resumes exactly where it stopped.
/// - push(): send every locally-dirty row (lastModifiedAt > watermark) —
///   inserts first (the server skips ids/externals it knows), then full
///   field patches. Rows whose stamp matches what we just applied from the
///   server are recognized as round-trips and skipped; the server also
///   treats no-op patches as seq-silent, so convergence is safe even
///   across app restarts and clock skew.
/// - seedAll(): one-time upload of the complete local history (tombstones
///   included). Completing it fast-forwards the cursor to the server's
///   counter (no point re-downloading our own upload) and flips the
///   enabled switch.
@Observable
final class ServerTransactionSync {

    static let shared = ServerTransactionSync()

    // UserDefaults keys (cursor + watermark survive relaunches).
    static let cursorKey = "serverTxnSyncCursor"
    static let lastPushedAtKey = "serverTxnLastPushedAt"
    static let enabledKey = "serverTxnSyncEnabled"

    var isSyncing = false
    var progress: String = ""
    var errorMessage: String?
    /// Seed progress 0...1 while seedAll() runs, nil otherwise.
    var seedProgress: Double?

    /// Injectable so tests can isolate their cursor/enabled state from the
    /// process-global standard defaults (which the app and .shared use).
    private let defaults: UserDefaults

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    private(set) var cursor: Int {
        get { defaults.integer(forKey: Self.cursorKey) }
        set { defaults.set(newValue, forKey: Self.cursorKey) }
    }

    private(set) var lastPushedAt: Date {
        get {
            let t = defaults.double(forKey: Self.lastPushedAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : .distantPast
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Self.lastPushedAtKey) }
    }

    /// Server stamps applied by pulls this session (id → lastModifiedAt).
    /// A row whose current stamp equals its entry here was not edited
    /// locally — it round-tripped from the server and push skips it.
    private var appliedStamps: [UUID: Date] = [:]

    private let service: ServerTransactionStoring
    private let database: DatabaseManager
    private var pushDebounceTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    /// True while pull() is writing — its own notifyDataChanged must not
    /// re-trigger the push debounce.
    private var isApplyingPull = false

    init(
        service: ServerTransactionStoring = PlaidService(),
        database: DatabaseManager = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.database = database
        self.defaults = defaults
        changeObserver = NotificationCenter.default.addObserver(
            forName: .localDataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.isApplyingPull else { return }
            self.schedulePush()
        }
    }

    /// Tests call this so a debounced push scheduled during arrangement
    /// can't fire into a mock after the test's assertions ran.
    func cancelPendingPush() {
        pushDebounceTask?.cancel()
        pushDebounceTask = nil
    }

    /// Rewind for a full re-sync (Settings → Re-sync, and the restore
    /// procedure in SECURITY.md): next pull re-walks the entire feed and
    /// next push re-offers everything — both idempotent (insert-skip,
    /// seq-silent no-op patches, LWW apply).
    func resetForFullResync() {
        cursor = 0
        lastPushedAt = .distantPast
        appliedStamps.removeAll()
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    /// Debounced push: local edits arrive in bursts (bulk categorize,
    /// imports), so wait for quiet before one consolidated push.
    func schedulePush(after seconds: Double = 3) {
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    /// Run a store call, waiting out 429s instead of failing. The bulk
    /// flows are bursty by nature (seed ≈ 32 POSTs, first pull ≈ 16 pages);
    /// the server's RateLimit-Reset header tells us when the window opens.
    private func withRateLimitRetry<T>(
        maxAttempts: Int = 5,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch PlaidService.PlaidServiceError.rateLimited(let retryAfter) {
                attempt += 1
                guard attempt < maxAttempts else {
                    throw PlaidService.PlaidServiceError.rateLimited(retryAfter: retryAfter)
                }
                let delay = retryAfter.map { min(max($0, 0.05), 70) } ?? 15
                progress = "Server is busy — retrying in \(max(1, Int(delay)))s…"
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: - Pull

    struct PullResult {
        var applied = 0
        var pages = 0
        var needsCategorization: [(transaction: Transaction, plaidPrimary: String?, plaidDetailed: String?)] = []
    }

    /// Pull everything after our cursor. Returns nil when disabled or on
    /// error (errorMessage is set).
    @discardableResult
    func pull() async -> PullResult? {
        guard isEnabled else { return nil }
        var result = PullResult()
        do {
            while true {
                let response = try await withRateLimitRetry {
                    try await service.fetchTransactionChanges(since: cursor, limit: 500)
                }
                if !response.changes.isEmpty {
                    isApplyingPull = true
                    let outcome = try database.applyServerChanges(response.changes)
                    isApplyingPull = false
                    result.applied += outcome.applied
                    result.needsCategorization.append(contentsOf: outcome.needsCategorization)
                    appliedStamps.merge(outcome.appliedStamps) { _, new in new }
                }
                result.pages += 1
                cursor = response.next_seq
                if !response.has_more { break }
            }
            if result.applied > 0 {
                isApplyingPull = true
                database.notifyDataChanged()
                isApplyingPull = false
            }
            return result
        } catch {
            isApplyingPull = false
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Push

    /// Send locally-dirty rows to the server. Insert-then-patch: inserts
    /// cover rows the server has never seen (imports, manual entries) and
    /// are skipped for known ids; patches carry every editable field so
    /// the server row converges to the local edit (LWW by arrival).
    func push() async {
        guard isEnabled else { return }
        let gatherStart = Date()
        do {
            let dirty = try database
                .fetchAllRecords(type: Transaction.self, since: lastPushedAt)
                .filter { row in
                    // Round-trip detection with sub-ms tolerance: GRDB
                    // stores Date at millisecond precision, so a pulled
                    // stamp never compares bit-equal after a fetch. A real
                    // local edit restamps with Date() — seconds away.
                    guard let stamp = appliedStamps[row.id] else { return true }
                    return abs(stamp.timeIntervalSince(row.lastModifiedAt)) > 0.0005
                }
            guard !dirty.isEmpty else {
                lastPushedAt = gatherStart
                return
            }

            for chunk in dirty.chunked(into: 250) {
                _ = try await withRateLimitRetry {
                    try await service.createTransactions(chunk.map(Self.uploadRow))
                }
            }
            for chunk in dirty.chunked(into: 250) {
                _ = try await withRateLimitRetry {
                    try await service.batchPatchTransactions(chunk.map { ($0.id.uuidString.lowercased(), Self.patchFields($0)) })
                }
            }
            // Watermark = gather start: an edit made mid-push lands in the
            // next cycle instead of being silently skipped.
            lastPushedAt = gatherStart
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Seed

    /// One-time full-history upload. Idempotent and resumable: the server
    /// skips every id/external_id it already has, so re-running after an
    /// interruption (or after a server restore from backup) is always safe.
    /// Returns true on success.
    func seedAll() async -> Bool {
        let gatherStart = Date()
        isSyncing = true
        seedProgress = 0
        errorMessage = nil
        defer {
            isSyncing = false
            seedProgress = nil
        }
        do {
            let all = try database.fetchAllTransactionsIncludingDeleted()
            guard !all.isEmpty else {
                // Nothing local — enable and pull whatever the server has.
                isEnabled = true
                lastPushedAt = gatherStart
                return true
            }
            let chunks = all.chunked(into: 250)
            for (index, chunk) in chunks.enumerated() {
                _ = try await withRateLimitRetry {
                    try await service.createTransactions(chunk.map(Self.uploadRow))
                }
                seedProgress = Double(index + 1) / Double(chunks.count)
                progress = "Uploaded \(min((index + 1) * 250, all.count)) of \(all.count)"
            }
            // The cursor deliberately does NOT fast-forward to the server's
            // counter: rows the server ingested from Plaid BEFORE/DURING the
            // seed sit at lower seqs than our upload, and jumping past them
            // loses them on this device forever (it happened: 10 real
            // transactions ingested mid-seed). The next pull re-walks
            // everything instead — idempotent, and rows we just uploaded
            // apply as cheap id-matched updates.
            lastPushedAt = gatherStart
            isEnabled = true
            progress = ""
            return true
        } catch {
            errorMessage = error.localizedDescription
            progress = ""
            return false
        }
    }

    // MARK: - Wire mapping

    static func uploadRow(_ txn: Transaction) -> PlaidService.ServerTransactionUpload {
        PlaidService.ServerTransactionUpload(
            id: txn.id.uuidString.lowercased(),
            date: DatabaseManager.serverDateString(from: txn.date),
            description: txn.description,
            merchant: txn.merchant,
            amount: txn.amount,
            category_id: txn.categoryId?.uuidString.lowercased(),
            is_manually_categorized: txn.isManuallyCategorized,
            external_id: txn.externalId,
            imported_file_id: txn.importedFileId.uuidString.lowercased(),
            source: txn.externalId != nil ? "plaid" : "import",
            is_deleted: txn.isDeleted
        )
    }

    /// Every server-patchable field, with NSNull for explicit clears.
    /// imported_file_id is intentionally absent: file grouping is not
    /// editable in any UI flow, and patching it would churn synthetic
    /// per-device "Plaid Sync" file ids across devices.
    static func patchFields(_ txn: Transaction) -> [String: Any] {
        [
            "description": txn.description,
            "merchant": txn.merchant ?? NSNull(),
            "amount": txn.amount,
            "date": DatabaseManager.serverDateString(from: txn.date),
            "category_id": txn.categoryId.map { $0.uuidString.lowercased() } ?? NSNull(),
            "is_manually_categorized": txn.isManuallyCategorized,
            "is_deleted": txn.isDeleted,
        ]
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
