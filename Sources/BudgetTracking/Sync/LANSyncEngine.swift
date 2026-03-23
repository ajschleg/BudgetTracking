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
        guard listener == nil else {
            logger.debug("start() called but listener already exists, skipping")
            return
        }

        logger.info("Starting LAN sync (deviceId: \(self.deviceId), deviceName: \(self.deviceName))")

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
        if connections.isEmpty {
            logger.info("syncNow() called but no connected peers")
            return
        }
        logger.info("syncNow() triggering sync with \(self.connections.count) peer(s)")
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
            if let port = listener?.port {
                logger.info("Listener ready on port \(port.rawValue)")
            } else {
                logger.info("Listener ready (port unknown)")
            }
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
        logger.debug("Browse results changed: \(results.count) result(s) found")
        var peers: [DiscoveredPeer] = []

        for result in results {
            let peerId: String
            let peerName: String

            if case .bonjour(let txt) = result.metadata {
                peerId = txt["deviceId"] ?? ""
                peerName = txt["deviceName"] ?? endpointDisplayName(result.endpoint)
                logger.debug("Found service with TXT: \(peerName) (id: \(peerId)) at \(String(describing: result.endpoint))")
            } else {
                // TXT record may not be resolved yet — use endpoint as temporary identity
                // and rely on the handshake to exchange real deviceId/deviceName
                peerId = ""
                peerName = endpointDisplayName(result.endpoint)
                logger.debug("Found service without TXT metadata: \(peerName) at \(String(describing: result.endpoint))")
            }

            // If we have a peerId and it's ourselves, skip
            if !peerId.isEmpty, peerId == deviceId {
                logger.debug("Filtering out self: \(peerId)")
                continue
            }

            // Check if we already have a connection for this peer (by peerId or endpoint)
            if !peerId.isEmpty, connections[peerId] != nil {
                peers.append(DiscoveredPeer(id: peerId, name: peerName, endpoint: result.endpoint))
                logger.debug("Already connected to \(peerName) (\(peerId)), skipping")
                continue
            }

            if connectionExists(for: result.endpoint) {
                peers.append(DiscoveredPeer(id: peerId.isEmpty ? result.endpoint.debugDescription : peerId, name: peerName, endpoint: result.endpoint))
                logger.debug("Already have connection to endpoint \(String(describing: result.endpoint)), skipping")
                continue
            }

            let effectiveId = peerId.isEmpty ? result.endpoint.debugDescription : peerId
            peers.append(DiscoveredPeer(id: effectiveId, name: peerName, endpoint: result.endpoint))
            connectToPeer(peerId: effectiveId, peerName: peerName, endpoint: result.endpoint)
        }

        Task { @MainActor in
            discoveredPeers = peers
        }
    }

    /// Extract a display name from a Bonjour endpoint.
    private func endpointDisplayName(_ endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint {
            return name
        }
        return endpoint.debugDescription
    }

    /// Check if any existing connection targets the given endpoint.
    private func connectionExists(for endpoint: NWEndpoint) -> Bool {
        connections.values.contains { $0.endpoint == endpoint }
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
        case .setup:
            logger.debug("Connection setup (incoming: \(isIncoming), peer: \(peerId ?? "unknown"))")

        case .preparing:
            logger.debug("Connection preparing (incoming: \(isIncoming), peer: \(peerId ?? "unknown"))")

        case .waiting(let error):
            logger.warning("Connection waiting: \(error) (incoming: \(isIncoming), peer: \(peerId ?? "unknown"))")

        case .ready:
            logger.info("Connection ready (incoming: \(isIncoming), peer: \(peerId ?? "unknown"), endpoint: \(String(describing: connection.endpoint)))")
            // Send handshake
            let info = PeerInfo(deviceId: deviceId, deviceName: deviceName, appVersion: "1.0")
            sendMessage(.handshake(info), on: connection)
            startReceiving(on: connection, peerId: peerId)

        case .failed(let error):
            logger.error("Connection failed: \(error) (incoming: \(isIncoming), peer: \(peerId ?? "unknown"))")
            if let peerId {
                connections.removeValue(forKey: peerId)
                receiveBuffers.removeValue(forKey: peerId)
            }
            updateConnectionStatus()

        case .cancelled:
            logger.debug("Connection cancelled (peer: \(peerId ?? "unknown"))")
            if let peerId {
                connections.removeValue(forKey: peerId)
                receiveBuffers.removeValue(forKey: peerId)
            }
            updateConnectionStatus()

        @unknown default:
            logger.debug("Connection unknown state (incoming: \(isIncoming), peer: \(peerId ?? "unknown"))")
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
        logger.debug("Sending \(message.typeDescription) to \(String(describing: connection.endpoint))")
        do {
            let data = try SyncWireProtocol.encode(message)
            logger.debug("Encoded \(message.typeDescription): \(data.count) bytes")
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.error("Send error for \(message.typeDescription): \(error)")
                } else {
                    self?.logger.debug("Successfully sent \(message.typeDescription)")
                }
            })
        } catch {
            logger.error("Failed to encode \(message.typeDescription): \(error)")
        }
    }

    private func startReceiving(on connection: NWConnection, peerId: String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            let effectivePeerId = peerId ?? "unknown"

            if let data {
                logger.debug("Received \(data.count) bytes from \(effectivePeerId)")
                var buffer = receiveBuffers[effectivePeerId] ?? Data()
                buffer.append(data)
                logger.debug("Buffer size for \(effectivePeerId): \(buffer.count) bytes")

                // Try to extract complete messages
                var decodeError: Error?
                while decodeError == nil {
                    do {
                        guard let message = try SyncWireProtocol.decode(from: &buffer) else {
                            break // Incomplete message, wait for more data
                        }
                        handleMessage(message, from: effectivePeerId, connection: connection)
                    } catch {
                        decodeError = error
                        logger.error("Failed to decode message from \(effectivePeerId): \(error)")
                        // Clear the buffer to avoid getting stuck on corrupt data
                        buffer = Data()
                    }
                }
                receiveBuffers[effectivePeerId] = buffer
            }

            if let error {
                self.logger.error("Receive error from \(effectivePeerId): \(error)")
                return
            }

            if isComplete {
                self.logger.debug("Connection receive completed for \(effectivePeerId)")
            } else {
                // Continue receiving
                self.startReceiving(on: connection, peerId: peerId)
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: SyncMessage, from peerId: String, connection: NWConnection) {
        logger.debug("Handling \(message.typeDescription) from \(peerId)")
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
            logger.debug("Handshake revealed self-connection, disconnecting")
            connection.cancel()
            return
        }

        logger.info("Handshake from: \(peerInfo.deviceName) (\(peerId))")

        // Re-key connection and buffer from temporary ID (endpoint description or "unknown") to real peerId
        let endpointKey = connection.endpoint.debugDescription
        for tempKey in ["unknown", endpointKey] {
            if let existingBuffer = receiveBuffers.removeValue(forKey: tempKey) {
                logger.debug("Re-keying buffer from '\(tempKey)' to '\(peerId)'")
                receiveBuffers[peerId] = existingBuffer
            }
            if connections.removeValue(forKey: tempKey) != nil {
                logger.debug("Re-keying connection from '\(tempKey)' to '\(peerId)'")
            }
        }
        connections[peerId] = connection

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
            logger.debug("Gathered \(categories.count) budgetCategory records since \(sinceDate)")

            let transactions = try DatabaseManager.shared.fetchAllRecords(
                type: Transaction.self, since: sinceDate
            )
            for txn in transactions {
                records.append(.from(txn, tableName: "transaction",
                                     id: txn.id.uuidString, isDeleted: txn.isDeleted,
                                     lastModifiedAt: txn.lastModifiedAt))
            }
            logger.debug("Gathered \(transactions.count) transaction records since \(sinceDate)")

            let files = try DatabaseManager.shared.fetchAllRecords(
                type: ImportedFile.self, since: sinceDate
            )
            for file in files {
                records.append(.from(file, tableName: "importedFile",
                                     id: file.id.uuidString, isDeleted: file.isDeleted,
                                     lastModifiedAt: file.lastModifiedAt))
            }
            logger.debug("Gathered \(files.count) importedFile records since \(sinceDate)")

            let rules = try DatabaseManager.shared.fetchAllRecords(
                type: CategorizationRule.self, since: sinceDate
            )
            for rule in rules {
                records.append(.from(rule, tableName: "categorizationRule",
                                     id: rule.id.uuidString, isDeleted: rule.isDeleted,
                                     lastModifiedAt: rule.lastModifiedAt))
            }
            logger.debug("Gathered \(rules.count) categorizationRule records since \(sinceDate)")

            let snapshots = try DatabaseManager.shared.fetchAllRecords(
                type: MonthlySnapshot.self, since: sinceDate
            )
            for snap in snapshots {
                records.append(.from(snap, tableName: "monthlySnapshot",
                                     id: snap.id.uuidString, isDeleted: snap.isDeleted,
                                     lastModifiedAt: snap.lastModifiedAt))
            }
            logger.debug("Gathered \(snapshots.count) monthlySnapshot records since \(sinceDate)")

            let profiles = try DatabaseManager.shared.fetchAllRecords(
                type: BankProfile.self, since: sinceDate
            )
            for profile in profiles {
                records.append(.from(profile, tableName: "bankProfile",
                                     id: profile.id.uuidString, isDeleted: profile.isDeleted,
                                     lastModifiedAt: profile.lastModifiedAt))
            }
            logger.debug("Gathered \(profiles.count) bankProfile records since \(sinceDate)")

            let response = SyncResponse(records: records, syncTimestamp: now)
            sendMessage(.syncResponse(response), on: connection)
            logger.info("Sent \(records.count) total records to \(peerId)")

        } catch {
            logger.error("Failed to gather records for sync response: \(error)")
        }
    }

    private func handleSyncResponse(_ response: SyncResponse, from peerId: String, connection: NWConnection) {
        logger.info("Received \(response.records.count) records from \(peerId)")

        // Capture the previous sync date BEFORE updating it — the reverse sync
        // must use this so locally edited records aren't skipped.
        let previousSyncDate = stateStore.lastSyncDate(forPeer: peerId)

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

        // Send our changes back using the PREVIOUS sync date so that records
        // edited between the last sync and now are included.
        let hasLocalChanges = hasRecordsSince(previousSyncDate)
        if hasLocalChanges {
            logger.info("Starting reverse sync to \(peerId) (since: \(previousSyncDate?.description ?? "beginning"))")
            handleSyncRequest(
                SyncRequest(sinceDate: previousSyncDate),
                from: peerId,
                connection: connection
            )
        } else {
            logger.info("No local changes to send to \(peerId), skipping reverse sync")
        }
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

    private func hasRecordsSince(_ date: Date?) -> Bool {
        let sinceDate = date ?? .distantPast
        do {
            let db = DatabaseManager.shared
            if !(try db.fetchAllRecords(type: BudgetCategory.self, since: sinceDate)).isEmpty { return true }
            if !(try db.fetchAllRecords(type: Transaction.self, since: sinceDate)).isEmpty { return true }
            if !(try db.fetchAllRecords(type: ImportedFile.self, since: sinceDate)).isEmpty { return true }
            if !(try db.fetchAllRecords(type: CategorizationRule.self, since: sinceDate)).isEmpty { return true }
            if !(try db.fetchAllRecords(type: MonthlySnapshot.self, since: sinceDate)).isEmpty { return true }
            if !(try db.fetchAllRecords(type: BankProfile.self, since: sinceDate)).isEmpty { return true }
        } catch {
            logger.error("Failed to check for local changes: \(error)")
        }
        return false
    }

    // MARK: - Push Changes to Peers

    private func debouncedPushToPeers() {
        guard isEnabled, !isApplyingPeerSync else {
            logger.debug("debouncedPushToPeers suppressed (isEnabled: \(self.isEnabled), isApplyingPeerSync: \(self.isApplyingPeerSync))")
            return
        }
        logger.debug("Scheduling debounced push to peers (1.5s delay)")

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
