import Foundation
import Network
import os.log
import GRDB

/// Discovers peers on the local network via Bonjour and syncs GRDB records bidirectionally.
@Observable
final class LANSyncEngine: @unchecked Sendable {

    enum LANSyncStatus: Equatable {
        case disabled
        case searching
        case connected(peerName: String)
        case syncing(peerName: String)
        case error(String)
    }

    struct DiscoveredPeer: Identifiable, Equatable {
        let id: String // deviceId
        let name: String
        let endpoint: NWEndpoint
    }

    // MARK: - Observable State

    private(set) var status: LANSyncStatus = .disabled
    private(set) var discoveredPeers: [DiscoveredPeer] = []
    private(set) var connectedPeerName: String?
    private(set) var lastLANSyncDate: Date?
    var isEnabled: Bool = false {
        didSet {
            if isEnabled { start() } else { stop() }
        }
    }

    // MARK: - Private State

    private let serviceType = "_budgetsync._tcp"
    private let logger = Logger(subsystem: "BudgetTracking", category: "LANSync")
    private let stateStore = LANSyncStateStore()

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:] // peerId -> connection
    private var peerInfoByEndpoint: [NWEndpoint: PeerInfo] = [:]
    private var receiveBuffers: [String: Data] = [:] // peerId -> buffer

    private let syncQueue = DispatchQueue(label: "com.schlegel.BudgetTracking.LANSync")

    /// This device's unique identity.
    private let deviceId: String
    private let deviceName: String

    /// Flag to suppress notifications when applying peer data.
    private var isApplyingPeerSync = false

    private var changeObserver: Any?
    private var debounceWorkItem: DispatchWorkItem?

    // MARK: - Init

    init() {
        // Generate or load a stable device ID
        if let existing = UserDefaults.standard.string(forKey: "LANSync_DeviceId") {
            deviceId = existing
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "LANSync_DeviceId")
            deviceId = newId
        }
        deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        // Listen for local data changes to push to peers
        changeObserver = NotificationCenter.default.addObserver(
            forName: .localDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.debouncedPushToPeers()
        }
    }

    deinit {
        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stop()
    }

    // MARK: - Start / Stop

    func start() {
        guard listener == nil else { return }

        logger.info("Starting LAN sync (deviceId: \(self.deviceId))")

        // Start listener (advertise ourselves)
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let lstn = try NWListener(using: params)
            lstn.service = NWListener.Service(type: serviceType, txtRecord: txtRecord())
            lstn.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            lstn.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }
            lstn.start(queue: syncQueue)
            listener = lstn
        } catch {
            logger.error("Failed to create listener: \(error)")
            Task { @MainActor in status = .error("Failed to start: \(error.localizedDescription)") }
            return
        }

        // Start browser (discover peers)
        let brwsr = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        brwsr.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        brwsr.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseResults(results)
        }
        brwsr.start(queue: syncQueue)
        browser = brwsr

        Task { @MainActor in status = .searching }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for conn in connections.values {
            conn.cancel()
        }
        connections.removeAll()
        receiveBuffers.removeAll()
        peerInfoByEndpoint.removeAll()

        Task { @MainActor in
            status = .disabled
            discoveredPeers = []
            connectedPeerName = nil
        }
    }

    /// Manually trigger a sync with all connected peers.
    func syncNow() {
        for (peerId, connection) in connections {
            initiateSync(with: peerId, connection: connection)
        }
    }

    // MARK: - TXT Record

    private func txtRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["deviceId"] = deviceId
        txt["deviceName"] = deviceName
        return txt
    }

    // MARK: - Listener Handlers

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("Listener ready")
        case .failed(let error):
            logger.error("Listener failed: \(error)")
            Task { @MainActor in status = .error("Listener: \(error.localizedDescription)") }
        case .cancelled:
            logger.info("Listener cancelled")
        default:
            break
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        logger.info("Incoming connection from \(String(describing: connection.endpoint))")
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(connection, state: state, isIncoming: true)
        }
        connection.start(queue: syncQueue)
    }

    // MARK: - Browser Handlers

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            logger.info("Browser ready, searching for peers...")
        case .failed(let error):
            logger.error("Browser failed: \(error)")
        default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var peers: [DiscoveredPeer] = []

        for result in results {
            guard case .bonjour(let txt) = result.metadata else { continue }
            let peerId = txt["deviceId"] ?? ""
            let peerName = txt["deviceName"] ?? "Unknown"

            // Don't discover ourselves
            guard peerId != deviceId, !peerId.isEmpty else { continue }

            peers.append(DiscoveredPeer(id: peerId, name: peerName, endpoint: result.endpoint))

            // Auto-connect if not already connected
            if connections[peerId] == nil {
                connectToPeer(peerId: peerId, peerName: peerName, endpoint: result.endpoint)
            }
        }

        Task { @MainActor in
            discoveredPeers = peers
        }
    }

    // MARK: - Connection Management

    private func connectToPeer(peerId: String, peerName: String, endpoint: NWEndpoint) {
        logger.info("Connecting to peer: \(peerName) (\(peerId))")

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(connection, state: state, isIncoming: false, peerId: peerId, peerName: peerName)
        }
        connection.start(queue: syncQueue)
    }

    private func handleConnectionState(
        _ connection: NWConnection,
        state: NWConnection.State,
        isIncoming: Bool,
        peerId: String? = nil,
        peerName: String? = nil
    ) {
        switch state {
        case .ready:
            logger.info("Connection ready (incoming: \(isIncoming))")
            // Send handshake
            let info = PeerInfo(deviceId: deviceId, deviceName: deviceName, appVersion: "1.0")
            sendMessage(.handshake(info), on: connection)
            startReceiving(on: connection, peerId: peerId)

        case .failed(let error):
            logger.error("Connection failed: \(error)")
            if let peerId {
                connections.removeValue(forKey: peerId)
                receiveBuffers.removeValue(forKey: peerId)
            }
            updateConnectionStatus()

        case .cancelled:
            if let peerId {
                connections.removeValue(forKey: peerId)
                receiveBuffers.removeValue(forKey: peerId)
            }
            updateConnectionStatus()

        default:
            break
        }
    }

    private func updateConnectionStatus() {
        Task { @MainActor in
            if let firstPeer = connections.keys.first,
               let endpoint = connections[firstPeer]?.endpoint {
                let name = discoveredPeers.first(where: { $0.id == firstPeer })?.name ?? "Peer"
                status = .connected(peerName: name)
                connectedPeerName = name
            } else if isEnabled {
                status = .searching
                connectedPeerName = nil
            }
        }
    }

    // MARK: - Message Send / Receive

    private func sendMessage(_ message: SyncMessage, on connection: NWConnection) {
        do {
            let data = try SyncWireProtocol.encode(message)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.error("Send error: \(error)")
                }
            })
        } catch {
            logger.error("Failed to encode message: \(error)")
        }
    }

    private func startReceiving(on connection: NWConnection, peerId: String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data {
                let effectivePeerId = peerId ?? "unknown"
                var buffer = receiveBuffers[effectivePeerId] ?? Data()
                buffer.append(data)

                // Try to extract complete messages
                while let message = try? SyncWireProtocol.decode(from: &buffer) {
                    handleMessage(message, from: effectivePeerId, connection: connection)
                }
                receiveBuffers[effectivePeerId] = buffer
            }

            if let error {
                self.logger.error("Receive error: \(error)")
                return
            }

            if !isComplete {
                // Continue receiving
                self.startReceiving(on: connection, peerId: peerId)
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: SyncMessage, from peerId: String, connection: NWConnection) {
        switch message {
        case .handshake(let peerInfo):
            handleHandshake(peerInfo, connection: connection)

        case .syncRequest(let request):
            handleSyncRequest(request, from: peerId, connection: connection)

        case .syncResponse(let response):
            handleSyncResponse(response, from: peerId, connection: connection)

        case .syncAck(let ack):
            handleSyncAck(ack, from: peerId)
        }
    }

    private func handleHandshake(_ peerInfo: PeerInfo, connection: NWConnection) {
        let peerId = peerInfo.deviceId
        guard peerId != deviceId else {
            // Connected to ourselves, disconnect
            connection.cancel()
            return
        }

        logger.info("Handshake from: \(peerInfo.deviceName) (\(peerId))")
        connections[peerId] = connection
        receiveBuffers[peerId] = receiveBuffers["unknown"] ?? Data()
        receiveBuffers.removeValue(forKey: "unknown")

        Task { @MainActor in
            status = .connected(peerName: peerInfo.deviceName)
            connectedPeerName = peerInfo.deviceName
        }

        // Start a sync exchange
        initiateSync(with: peerId, connection: connection)
    }

    private func initiateSync(with peerId: String, connection: NWConnection) {
        let sinceDate = stateStore.lastSyncDate(forPeer: peerId)
        let request = SyncRequest(sinceDate: sinceDate)
        sendMessage(.syncRequest(request), on: connection)
        logger.info("Sent sync request to \(peerId) (since: \(sinceDate?.description ?? "beginning"))")
    }

    private func handleSyncRequest(_ request: SyncRequest, from peerId: String, connection: NWConnection) {
        logger.info("Received sync request from \(peerId)")

        let sinceDate = request.sinceDate ?? .distantPast
        let now = Date()

        do {
            var records: [SyncRecord] = []

            // Gather all records modified since the requested date
            let categories = try DatabaseManager.shared.fetchAllRecords(
                type: BudgetCategory.self, since: sinceDate
            )
            for cat in categories {
                records.append(.from(cat, tableName: "budgetCategory",
                                     id: cat.id.uuidString, isDeleted: cat.isDeleted,
                                     lastModifiedAt: cat.lastModifiedAt))
            }

            let transactions = try DatabaseManager.shared.fetchAllRecords(
                type: Transaction.self, since: sinceDate
            )
            for txn in transactions {
                records.append(.from(txn, tableName: "transaction",
                                     id: txn.id.uuidString, isDeleted: txn.isDeleted,
                                     lastModifiedAt: txn.lastModifiedAt))
            }

            let files = try DatabaseManager.shared.fetchAllRecords(
                type: ImportedFile.self, since: sinceDate
            )
            for file in files {
                records.append(.from(file, tableName: "importedFile",
                                     id: file.id.uuidString, isDeleted: file.isDeleted,
                                     lastModifiedAt: file.lastModifiedAt))
            }

            let rules = try DatabaseManager.shared.fetchAllRecords(
                type: CategorizationRule.self, since: sinceDate
            )
            for rule in rules {
                records.append(.from(rule, tableName: "categorizationRule",
                                     id: rule.id.uuidString, isDeleted: rule.isDeleted,
                                     lastModifiedAt: rule.lastModifiedAt))
            }

            let snapshots = try DatabaseManager.shared.fetchAllRecords(
                type: MonthlySnapshot.self, since: sinceDate
            )
            for snap in snapshots {
                records.append(.from(snap, tableName: "monthlySnapshot",
                                     id: snap.id.uuidString, isDeleted: snap.isDeleted,
                                     lastModifiedAt: snap.lastModifiedAt))
            }

            let profiles = try DatabaseManager.shared.fetchAllRecords(
                type: BankProfile.self, since: sinceDate
            )
            for profile in profiles {
                records.append(.from(profile, tableName: "bankProfile",
                                     id: profile.id.uuidString, isDeleted: profile.isDeleted,
                                     lastModifiedAt: profile.lastModifiedAt))
            }

            let response = SyncResponse(records: records, syncTimestamp: now)
            sendMessage(.syncResponse(response), on: connection)
            logger.info("Sent \(records.count) records to \(peerId)")

        } catch {
            logger.error("Failed to gather records for sync response: \(error)")
        }
    }

    private func handleSyncResponse(_ response: SyncResponse, from peerId: String, connection: NWConnection) {
        logger.info("Received \(response.records.count) records from \(peerId)")

        Task { @MainActor in
            if let name = connectedPeerName {
                status = .syncing(peerName: name)
            }
        }

        var appliedCount = 0
        let decoder = JSONDecoder()

        isApplyingPeerSync = true
        defer { isApplyingPeerSync = false }

        for record in response.records {
            do {
                switch record.tableName {
                case "budgetCategory":
                    let model = try decoder.decode(BudgetCategory.self, from: record.jsonData)
                    if try DatabaseManager.shared.upsertFromPeer(model) {
                        appliedCount += 1
                    }

                case "transaction":
                    let model = try decoder.decode(Transaction.self, from: record.jsonData)
                    if try DatabaseManager.shared.upsertFromPeer(model) {
                        appliedCount += 1
                    }

                case "importedFile":
                    let model = try decoder.decode(ImportedFile.self, from: record.jsonData)
                    if try DatabaseManager.shared.upsertFromPeer(model) {
                        appliedCount += 1
                    }

                case "categorizationRule":
                    let model = try decoder.decode(CategorizationRule.self, from: record.jsonData)
                    if try DatabaseManager.shared.upsertFromPeer(model) {
                        appliedCount += 1
                    }

                case "monthlySnapshot":
                    let model = try decoder.decode(MonthlySnapshot.self, from: record.jsonData)
                    if try DatabaseManager.shared.upsertFromPeer(model) {
                        appliedCount += 1
                    }

                case "bankProfile":
                    let model = try decoder.decode(BankProfile.self, from: record.jsonData)
                    if try DatabaseManager.shared.upsertFromPeer(model) {
                        appliedCount += 1
                    }

                default:
                    logger.warning("Unknown table in sync record: \(record.tableName)")
                }
            } catch {
                logger.error("Failed to apply sync record (\(record.tableName) \(record.recordId)): \(error)")
            }
        }

        // Send ack
        let ack = SyncAck(syncTimestamp: response.syncTimestamp, recordsApplied: appliedCount)
        sendMessage(.syncAck(ack), on: connection)

        // Update state
        stateStore.setLastSyncDate(response.syncTimestamp, forPeer: peerId)

        logger.info("Applied \(appliedCount) records from \(peerId)")

        Task { @MainActor in
            lastLANSyncDate = Date()
            if let name = connectedPeerName {
                status = .connected(peerName: name)
            }
            // Notify views to reload
            NotificationCenter.default.post(name: .lanSyncDidComplete, object: nil)
        }

        // Now send our changes back
        handleSyncRequest(
            SyncRequest(sinceDate: stateStore.lastSyncDate(forPeer: peerId)),
            from: peerId,
            connection: connection
        )
    }

    private func handleSyncAck(_ ack: SyncAck, from peerId: String) {
        logger.info("Sync ack from \(peerId): \(ack.recordsApplied) records applied")
        stateStore.setLastSyncDate(ack.syncTimestamp, forPeer: peerId)

        Task { @MainActor in
            lastLANSyncDate = Date()
            if let name = connectedPeerName {
                status = .connected(peerName: name)
            }
        }
    }

    // MARK: - Push Changes to Peers

    private func debouncedPushToPeers() {
        guard isEnabled, !isApplyingPeerSync else { return }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.syncNow()
        }
        debounceWorkItem = work
        syncQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let lanSyncDidComplete = Notification.Name("lanSyncDidComplete")
}
