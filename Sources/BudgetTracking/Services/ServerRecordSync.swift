import Foundation
import SwiftUI

/// The record-store slice of PlaidService used by ServerRecordSync.
protocol ServerRecordStoring {
    func fetchRecordChanges(since: Int, limit: Int) async throws -> PlaidService.RecordChangesResponse
    func pushRecords(_ rows: [PlaidService.RecordUpload]) async throws -> PlaidService.RecordBulkResponse
}

extension PlaidService: ServerRecordStoring {}

/// Keeps the five metadata record types (categories, rules, snapshots,
/// bank profiles, imported files) converged with the server's generic
/// record store — the Phase 3 sibling of ServerTransactionSync, sharing
/// its design: cursor pull, watermark push, round-trip stamp filtering,
/// rate-limit patience, debounced push on local changes.
///
/// Differences from the transactions service, both deliberate:
/// - Enablement REUSES `serverTxnSyncEnabled` — one switch, one mental
///   model ("server sync is on").
/// - The first run seeds PULL-FIRST: merge whatever the server already
///   has (another device's records, or nothing) and only then push local
///   rows that didn't round-trip. On second devices the push side of the
///   seed is therefore a near-no-op, which is what makes same-name
///   category floods impossible.
@Observable
final class ServerRecordSync {

    static let shared = ServerRecordSync()

    static let cursorKey = "serverRecSyncCursor"
    static let lastPushedAtKey = "serverRecLastPushedAt"
    static let seededKey = "serverRecSeeded"

    var isSyncing = false
    var progress: String = ""
    var errorMessage: String?

    private let defaults: UserDefaults

    /// Same switch the transactions feed uses (flipped by completing the
    /// transactions seed in Settings).
    var isEnabled: Bool {
        defaults.bool(forKey: ServerTransactionSync.enabledKey)
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

    private(set) var hasSeeded: Bool {
        get { defaults.bool(forKey: Self.seededKey) }
        set { defaults.set(newValue, forKey: Self.seededKey) }
    }

    /// Server stamps applied by pulls this session, keyed "type/id".
    private var appliedStamps: [String: Date] = [:]

    private let service: ServerRecordStoring
    private let database: DatabaseManager
    private var pushDebounceTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var isApplyingPull = false

    init(
        service: ServerRecordStoring = PlaidService(),
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

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func cancelPendingPush() {
        pushDebounceTask?.cancel()
        pushDebounceTask = nil
    }

    func schedulePush(after seconds: Double = 3) {
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    /// Launch entry point: seed once (pull-first), then converge.
    func syncIfNeeded() async {
        guard isEnabled, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        if !hasSeeded {
            progress = "Syncing budgets and categories with server…"
            await pull()
            await push(since: .distantPast)   // everything not round-tripped
            hasSeeded = true
            progress = ""
        } else {
            await pull()
            await push()
        }
    }

    // MARK: - Pull

    struct PullResult {
        var applied = 0
        var pages = 0
    }

    @discardableResult
    func pull() async -> PullResult? {
        guard isEnabled else { return nil }
        var result = PullResult()
        do {
            while true {
                let response = try await withRateLimitRetry {
                    try await service.fetchRecordChanges(since: cursor, limit: 500)
                }
                if !response.changes.isEmpty {
                    isApplyingPull = true
                    let outcome = try database.applyServerRecords(response.changes)
                    isApplyingPull = false
                    result.applied += outcome.applied
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

    func push(since override: Date? = nil) async {
        guard isEnabled else { return }
        let gatherStart = Date()
        do {
            let candidates = try database
                .gatherRecordUploads(since: override ?? lastPushedAt)
                .filter { candidate in
                    guard let stamp = appliedStamps[candidate.stampKey] else { return true }
                    return abs(stamp.timeIntervalSince(candidate.lastModifiedAt)) > 0.0005
                }
            guard !candidates.isEmpty else {
                lastPushedAt = gatherStart
                return
            }
            for chunk in candidates.map(\.upload).chunkedForRecords(into: 250) {
                _ = try await withRateLimitRetry {
                    try await service.pushRecords(chunk)
                }
            }
            lastPushedAt = gatherStart
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Rate-limit patience (mirror of ServerTransactionSync)

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
}

private extension Array {
    func chunkedForRecords(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
