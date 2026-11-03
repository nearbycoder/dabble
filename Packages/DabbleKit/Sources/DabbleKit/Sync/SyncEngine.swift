import CryptoKit
import Foundation
import Network
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Device-to-device sync with no server.
///
/// Devices that share a *sync group key* find each other with Bonjour on the
/// local network (including Apple's peer-to-peer Wi-Fi, so two devices sync
/// even without a router) or at a manually entered address (handy over a VPN
/// such as Tailscale). Each pair opens a `SecureChannel` keyed by the group
/// key and exchanges the records the other hasn't seen, then keeps pushing
/// changes while connected.
///
/// Optionally, the group can also sync through a self-hosted relay (see
/// `server/` and `Relay.swift`) for devices that are rarely on the same
/// network. The relay only ever stores ciphertext.
///
/// A new device joins the group by pairing. Both devices show the same
/// six-digit code, derived from their handshake with a commit/reveal step
/// (as in Bluetooth numeric comparison); once the user confirms the codes
/// match on both, the group key is handed over. There is no secret to guess,
/// so nothing can be brute-forced offline, and a man in the middle gets one
/// try with a one-in-a-million chance of producing matching codes.
@MainActor
@Observable
public final class SyncEngine {
    public static let serviceType = "_dabble._tcp"
    public static let pairingServiceType = "_dabble-pair._tcp"
    public static let defaultPort: UInt16 = 52384

    public struct Peer: Identifiable, Hashable, Sendable {
        public let id: String
        public var name: String
        public var platform: String
        public var isConnected: Bool
        public var lastSync: Date?
    }

    /// A device on the network that is waiting to pair.
    public struct PairingHost: Identifiable, Hashable, @unchecked Sendable {
        public let id: String
        public let name: String
        let endpoint: NWEndpoint

        public static func address(_ host: String, port: UInt16) -> PairingHost {
            PairingHost(id: "\(host):\(port)", name: host, endpoint: .hostPort(host: .init(host), port: .init(rawValue: port)!))
        }
    }

    public enum PairingStatus: Equatable, Sendable {
        case idle
        /// Discoverable and waiting for another device to join.
        case hosting
        /// Connecting to the chosen device.
        case joining
        /// Both devices show `code`; the user must confirm it matches on both.
        case confirm(device: String, code: String)
        /// Confirmed here; waiting for the user to confirm on the other device.
        case waiting(device: String)
        case paired(with: String)
        case failed(String)
    }

    // MARK: Observable state

    public private(set) var peers: [Peer] = []
    public private(set) var isRunning = false
    public private(set) var pairingStatus: PairingStatus = .idle
    public private(set) var pairingHosts: [PairingHost] = []
    public private(set) var listenerPort: UInt16?
    public private(set) var pairingPort: UInt16?
    public private(set) var lastError: String?
    public private(set) var lastSync: Date?
    public private(set) var manualPeers: [String] = []

    public enum ServerStatus: Equatable, Sendable {
        /// No server configured, sync is off, or there's no sync group yet.
        case off
        case connecting
        case connected
        case error(String)
    }

    /// The optional sync server, if one is set.
    public private(set) var serverURL: URL?
    public private(set) var serverStatus: ServerStatus = .off
    public private(set) var serverLastSync: Date?

    public var deviceName: String {
        didSet {
            guard deviceName != oldValue else { return }
            settings.deviceName = deviceName
            saveSettings()
            if isRunning { restart() }
        }
    }

    public var isEnabled: Bool {
        get { settings.enabled }
        set {
            settings.enabled = newValue
            saveSettings()
            newValue ? start() : stop()
        }
    }

    public var hasGroup: Bool { settings.groupKey != nil }

    /// Short fingerprint of the sync group, shown so people can check two devices match.
    public var groupID: String? { settings.groupKey.map(Self.groupID(for:)) }

    public var platform: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        "Apple"
        #endif
    }

    // MARK: Internals

    private struct PeerRecord: Codable {
        var name: String
        var platform: String
        /// Highest sequence number of theirs we've merged.
        var cursor: Int64
        var lastSync: Date?
    }

    private struct Settings: Codable {
        var groupKey: Data?
        var deviceName: String?
        var enabled = true
        var peers: [String: PeerRecord] = [:]
        var manualPeers: [String] = []
        // Optional sync server. Optional fields so older settings files still decode.
        var serverURL: String?
        var serverPushed: Int64?
        var serverCursor: Int?
    }

    private enum Message: Codable {
        case hello(deviceID: String, name: String, platform: String)
        case request(since: Int64)
        case changes(records: [Record], upTo: Int64)
        case grant(groupKey: Data, server: String?)
        // Pairing: the joiner commits to a nonce, the host sends its own, the
        // joiner reveals. Both then derive the comparison code.
        case commit(Data)
        case nonce(Data)
        case reveal(Data)
        case confirmed
    }

    private final class Session {
        let channel: SecureChannel
        let purpose: Purpose
        /// Device id we expect, if we dialed a discovered peer.
        let expectedPeer: String?
        var peerID: String?
        var peerName = ""
        var platform = ""
        var helloReceived = false
        var requested = false
        var sentCursor: Int64 = 0
        // Pairing state.
        var myNonce = Data()
        var theirCommitment: Data?
        var theirNonce: Data?
        var code: String?
        var confirmedHere = false
        var confirmedThere = false

        enum Purpose { case sync, hostPairing, joinPairing }

        init(channel: SecureChannel, purpose: Purpose, expectedPeer: String?) {
            self.channel = channel
            self.purpose = purpose
            self.expectedPeer = expectedPeer
        }
    }

    private let store: DabbleStore
    private let settingsURL: URL?
    private let preferredPort: UInt16?
    private let discovery: Bool
    @ObservationIgnored private var settings: Settings
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var pairingListener: NWListener?
    @ObservationIgnored private var pairingBrowser: NWBrowser?
    @ObservationIgnored private var pairingSession: Session?
    @ObservationIgnored private var sessions: [ObjectIdentifier: Session] = [:]
    @ObservationIgnored private var browseResults: Set<NWBrowser.Result> = []
    @ObservationIgnored private var dialing: Set<String> = []
    /// Device ids behind manually added addresses, learned on first connect.
    @ObservationIgnored private var manualPeerIDs: [String: String] = [:]
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var pushTask: Swift.Task<Void, Never>?
    @ObservationIgnored private var timer: Swift.Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Swift.Task<Void, Never>?
    @ObservationIgnored private var pairingTimeout: Swift.Task<Void, Never>?

    /// - Parameters:
    ///   - directory: where sync settings live (next to the store). Nil keeps them in memory.
    ///   - port: listening port. Nil tries `defaultPort` and falls back to any free port; 0 means any.
    ///   - discovery: advertise and browse with Bonjour. Turned off in tests.
    public init(store: DabbleStore, directory: URL?, port: UInt16? = nil, discovery: Bool = true) {
        self.store = store
        settingsURL = directory?.appendingPathComponent("sync.json")
        preferredPort = port
        self.discovery = discovery
        if let settingsURL, let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
        deviceName = settings.deviceName ?? Self.defaultDeviceName
        manualPeers = settings.manualPeers
        serverURL = settings.serverURL.flatMap(URL.init(string:))
        refreshPeers()
    }

    static var defaultDeviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        UIDevice.current.name
        #else
        "Device"
        #endif
    }

    static func groupID(for key: Data) -> String {
        let digest = SHA256.hash(data: key + Data("dabble-group-id".utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Pairing channels aren't keyed by a secret; they're authenticated by the
    /// user comparing codes. This constant just separates them from sync channels.
    static let pairingPSK = SymmetricKey(data: SHA256.hash(data: Data("dabble-pairing-v2".utf8)))

    static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func commitment(_ nonce: Data, transcript: Data) -> Data {
        Data(SHA256.hash(data: Data("dabble-commit".utf8) + transcript + nonce))
    }

    /// Six digits both devices display. The joiner's nonce is committed before
    /// the host's is known, so neither side (nor anyone in between) can steer it.
    static func comparisonCode(transcript: Data, hostNonce: Data, joinerNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("dabble-sas".utf8) + transcript + hostNonce + joinerNonce))
        let value = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06d", value)
        return digits.prefix(3) + " " + digits.suffix(3)
    }

    // MARK: - Lifecycle

    /// Starts listening and looking for peers. Safe to call repeatedly.
    public func start() {
        guard settings.enabled, !isRunning else { return }
        isRunning = true
        if settings.serverURL != nil && settings.groupKey == nil {
            // A server needs a group to sync into.
            adoptGroupKey(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
            saveSettings(immediately: true)
        }
        if observerToken == nil {
            observerToken = store.observe { [weak self] _ in
                self?.schedulePush()
                self?.scheduleRelayPush()
            }
        }
        startRelay()
        startListener(port: preferredPort ?? Self.defaultPort, allowFallback: preferredPort == nil)
        if discovery { startBrowser() }
        timer = Swift.Task { [weak self] in
            while !Swift.Task.isCancelled {
                try? await Swift.Task.sleep(for: .seconds(15))
                self?.connectToKnownPeers()
            }
        }
        connectToKnownPeers()
    }

    public func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        listenerPort = nil
        for session in sessions.values where session.purpose == .sync { session.channel.close() }
        stopRelay()
        refreshPeers()
    }

    public func restart() {
        stop()
        start()
    }

    /// Call when the app comes to the foreground: reconnects anything the OS tore down.
    public func resume() {
        if !isRunning || listener == nil {
            restart()
        } else {
            connectToKnownPeers()
        }
    }

    /// Reconnects to peers right away.
    public func syncNow() {
        resume()
        schedulePush()
        if isRunning {
            // Cut a long poll short so the server round-trips right away.
            stopRelay()
            startRelay()
        }
    }

    // MARK: - Group management

    /// Leaves the sync group: this device stops syncing and forgets its peers.
    /// The data on this device stays.
    public func leaveGroup() {
        stop()
        adoptGroupKey(nil)
        settings.peers = [:]
        settings.serverURL = nil
        serverURL = nil
        serverLastSync = nil
        saveSettings(immediately: true)
        refreshPeers()
        // Stay ready to pair again.
        start()
    }

    public func forget(peer id: String) {
        settings.peers[id] = nil
        for session in sessions.values where session.peerID == id { session.channel.close() }
        saveSettings()
        refreshPeers()
    }

    /// Adds an address like "192.168.1.20:52384" or "my-mac.tailnet.ts.net:52384".
    public func addManualPeer(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard Self.parseAddress(trimmed) != nil, !settings.manualPeers.contains(trimmed) else { return }
        settings.manualPeers.append(trimmed)
        manualPeers = settings.manualPeers
        saveSettings()
        connectToKnownPeers()
    }

    public func removeManualPeer(_ address: String) {
        settings.manualPeers.removeAll { $0 == address }
        manualPeers = settings.manualPeers
        saveSettings()
    }

    public static func parseAddress(_ address: String) -> (String, UInt16)? {
        guard let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]) else {
            return address.isEmpty ? nil : (address, defaultPort)
        }
        let host = String(address[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, port)
    }

    /// Joins a group directly with its key. Used by tests and backups.
    public func setGroupKey(_ key: Data) {
        adoptGroupKey(key)
        saveSettings(immediately: true)
        if isRunning { restart() }
    }

    private func ensureGroup() -> Data {
        if let key = settings.groupKey { return key }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        adoptGroupKey(key)
        saveSettings(immediately: true)
        if settings.enabled { restart() }
        return key
    }

    // MARK: - Pairing (host side)

    /// Makes this device discoverable so another device can join its sync group.
    public func startHostingPairing() {
        stopHostingPairing()
        _ = ensureGroup()
        pairingStatus = .hosting

        do {
            let listener = try NWListener(using: Self.parameters(), on: .any)
            if discovery {
                listener.service = NWListener.Service(name: deviceName, type: Self.pairingServiceType)
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.acceptPairing(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .ready = state { self.pairingPort = listener.port?.rawValue }
                    if case .failed(let error) = state { self.pairingStatus = .failed(error.localizedDescription) }
                }
            }
            listener.start(queue: .main)
            pairingListener = listener
        } catch {
            pairingStatus = .failed(error.localizedDescription)
        }
        pairingTimeout = Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .seconds(300))
            guard !Swift.Task.isCancelled else { return }
            self?.stopHostingPairing()
        }
    }

    public func stopHostingPairing() {
        pairingTimeout?.cancel()
        pairingListener?.cancel()
        pairingListener = nil
        pairingPort = nil
        if pairingSession?.purpose == .hostPairing {
            pairingSession?.channel.close()
            pairingSession = nil
        }
        switch pairingStatus {
        case .hosting, .confirm, .waiting: pairingStatus = .idle
        default: break
        }
    }

    private func acceptPairing(_ connection: NWConnection) {
        // One pairing at a time.
        guard pairingListener != nil, pairingSession == nil else {
            connection.cancel()
            return
        }
        let channel = SecureChannel(connection: connection, psk: Self.pairingPSK, purpose: "pair", outgoing: false)
        let session = Session(channel: channel, purpose: .hostPairing, expectedPeer: nil)
        pairingSession = session
        attach(session)
        channel.start()
    }

    /// The user checked that both devices show the same code.
    public func confirmPairing() {
        guard let session = pairingSession, session.code != nil, !session.confirmedHere else { return }
        session.confirmedHere = true
        send(.confirmed, on: session)
        if session.purpose == .hostPairing && session.confirmedThere {
            grant(to: session)
        } else {
            pairingStatus = .waiting(device: session.peerName)
        }
    }

    /// The codes didn't match, or the user changed their mind.
    public func rejectPairing() {
        guard let session = pairingSession else { return }
        pairingSession = nil
        session.channel.close()
        if session.purpose == .hostPairing && pairingListener != nil {
            pairingStatus = .hosting
        } else {
            pairingStatus = .failed("Pairing was canceled.")
        }
    }

    private func grant(to session: Session) {
        guard let key = settings.groupKey, let peerID = session.peerID else { return }
        send(.grant(groupKey: key, server: settings.serverURL), on: session)
        settings.peers[peerID] = settings.peers[peerID] ?? PeerRecord(name: session.peerName, platform: session.platform, cursor: 0)
        saveSettings()
        let name = session.peerName
        pairingSession = nil
        stopHostingPairing()
        pairingStatus = .paired(with: name)
        refreshPeers()
        connectToKnownPeers()
    }

    // MARK: - Pairing (joining side)

    /// Looks for devices that are ready to pair.
    public func startBrowsingForPairing() {
        stopBrowsingForPairing()
        guard discovery else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.pairingServiceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.pairingHosts = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return PairingHost(id: "\(result.endpoint)", name: name, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        pairingBrowser = browser
    }

    public func stopBrowsingForPairing() {
        pairingBrowser?.cancel()
        pairingBrowser = nil
        pairingHosts = []
    }

    /// Starts joining the sync group of `host`. Both devices then show a code
    /// to compare (`PairingStatus.confirm`). Data on this device is kept and
    /// merged with the group's.
    public func join(_ host: PairingHost) {
        pairingSession?.channel.close()
        pairingStatus = .joining
        let connection = NWConnection(to: host.endpoint, using: Self.parameters())
        let channel = SecureChannel(connection: connection, psk: Self.pairingPSK, purpose: "pair", outgoing: true)
        let session = Session(channel: channel, purpose: .joinPairing, expectedPeer: nil)
        pairingSession = session
        attach(session)
        channel.start()
    }

    public func resetPairingStatus() {
        switch pairingStatus {
        case .hosting, .confirm, .waiting: return
        default: pairingStatus = .idle
        }
    }

    // MARK: - Networking

    nonisolated static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func startListener(port: UInt16, allowFallback: Bool) {
        guard settings.groupKey != nil else { return }
        do {
            let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
            let listener = try NWListener(using: Self.parameters(), on: nwPort)
            if discovery, let groupID {
                var txt = NWTXTRecord()
                txt["d"] = store.deviceID
                txt["g"] = groupID
                listener.service = NWListener.Service(name: deviceName, type: Self.serviceType, txtRecord: txt)
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.listenerPort = listener.port?.rawValue
                        self.lastError = nil
                    case .failed(let error):
                        listener.cancel()
                        self.listener = nil
                        if allowFallback && port != 0 {
                            self.startListener(port: 0, allowFallback: false)
                        } else {
                            self.lastError = "Couldn't listen for other devices: \(error.localizedDescription)"
                        }
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            if allowFallback && port != 0 {
                startListener(port: 0, allowFallback: false)
            } else {
                lastError = "Couldn't listen for other devices: \(error.localizedDescription)"
            }
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.browseResults = results
                self?.connectToKnownPeers()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state { self?.lastError = "Couldn't look for other devices: \(error.localizedDescription)" }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func accept(_ connection: NWConnection) {
        guard let key = settings.groupKey else {
            connection.cancel()
            return
        }
        let channel = SecureChannel(connection: connection, psk: SymmetricKey(data: key), purpose: "sync", outgoing: false)
        attach(Session(channel: channel, purpose: .sync, expectedPeer: nil))
        channel.start()
    }

    /// Dials every discovered or manually added peer we aren't connected to.
    private func connectToKnownPeers() {
        guard isRunning, let key = settings.groupKey, let groupID else { return }
        for result in browseResults {
            guard case .bonjour(let txt) = result.metadata, let peerID = txt["d"], txt["g"] == groupID,
                  peerID != store.deviceID, !isConnected(peerID), !dialing.contains(peerID) else { continue }
            dial(result.endpoint, key: key, dialKey: peerID, expectedPeer: peerID)
        }
        for address in settings.manualPeers where !dialing.contains(address) {
            guard let (host, port) = Self.parseAddress(address), let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
            // Skip addresses whose device is already connected some other way.
            if let peerID = manualPeerIDs[address], isConnected(peerID) { continue }
            dial(.hostPort(host: .init(host), port: nwPort), key: key, dialKey: address, expectedPeer: address)
        }
    }

    private func dial(_ endpoint: NWEndpoint, key: Data, dialKey: String, expectedPeer: String) {
        dialing.insert(dialKey)
        let connection = NWConnection(to: endpoint, using: Self.parameters())
        let channel = SecureChannel(connection: connection, psk: SymmetricKey(data: key), purpose: "sync", outgoing: true)
        let session = Session(channel: channel, purpose: .sync, expectedPeer: expectedPeer)
        attach(session, dialKey: dialKey)
        channel.start()
    }

    private func isConnected(_ peerID: String) -> Bool {
        sessions.values.contains { $0.purpose == .sync && $0.helloReceived && $0.peerID == peerID }
    }

    private func attach(_ session: Session, dialKey: String? = nil) {
        let id = ObjectIdentifier(session)
        sessions[id] = session
        session.channel.onReady = { [weak self, weak session] in
            guard let self, let session else { return }
            self.send(.hello(deviceID: self.store.deviceID, name: self.deviceName, platform: self.platform), on: session)
        }
        session.channel.onMessage = { [weak self, weak session] data in
            guard let self, let session else { return }
            self.receive(data, on: session)
        }
        session.channel.onClose = { [weak self, weak session] error in
            guard let self else { return }
            if let dialKey { self.dialing.remove(dialKey) }
            let closed = self.sessions.removeValue(forKey: id) ?? session
            if let closed { self.sessionClosed(closed, error: error) }
            self.refreshPeers()
        }
    }

    private func sessionClosed(_ session: Session, error: Error?) {
        guard session.purpose != .sync, pairingSession === session else { return }
        pairingSession = nil
        switch pairingStatus {
        case .joining, .confirm, .waiting:
            if session.purpose == .hostPairing && pairingListener != nil {
                pairingStatus = .hosting
            } else {
                pairingStatus = .failed(error?.localizedDescription ?? "The other device disconnected.")
            }
        default:
            break
        }
    }

    private func send(_ message: Message, on session: Session) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        session.channel.send(data)
    }

    private func receive(_ data: Data, on session: Session) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
            session.channel.close(SecureChannel.ChannelError.protocolViolation)
            return
        }
        switch (message, session.purpose) {
        case (.hello(let deviceID, let name, let platform), _):
            guard deviceID != store.deviceID else {
                session.channel.close()
                return
            }
            session.peerID = deviceID
            session.peerName = name
            session.platform = platform
            session.helloReceived = true
            if let address = session.expectedPeer, settings.manualPeers.contains(address) { manualPeerIDs[address] = deviceID }
            handleHello(on: session)

        case (.request(let since), .sync):
            session.requested = true
            pushChanges(to: session, since: since)

        case (.changes(let records, let upTo), .sync):
            guard let peerID = session.peerID else { return }
            store.merge(records)
            var record = settings.peers[peerID] ?? PeerRecord(name: session.peerName, platform: session.platform, cursor: 0)
            record.cursor = max(record.cursor, upTo)
            record.lastSync = Date()
            settings.peers[peerID] = record
            lastSync = record.lastSync
            saveSettings()
            refreshPeers()

        case (.commit(let commitment), .hostPairing):
            guard session.helloReceived, session.theirCommitment == nil, commitment.count == 32 else {
                session.channel.close(SecureChannel.ChannelError.protocolViolation)
                return
            }
            session.theirCommitment = commitment
            session.myNonce = Self.randomNonce()
            send(.nonce(session.myNonce), on: session)

        case (.nonce(let nonce), .joinPairing):
            guard session.theirNonce == nil, !session.myNonce.isEmpty, let transcript = session.channel.transcript else {
                session.channel.close(SecureChannel.ChannelError.protocolViolation)
                return
            }
            session.theirNonce = nonce
            send(.reveal(session.myNonce), on: session)
            session.code = Self.comparisonCode(transcript: transcript, hostNonce: nonce, joinerNonce: session.myNonce)
            pairingStatus = .confirm(device: session.peerName, code: session.code!)

        case (.reveal(let nonce), .hostPairing):
            guard let commitment = session.theirCommitment, session.code == nil, let transcript = session.channel.transcript,
                  Self.commitment(nonce, transcript: transcript) == commitment else {
                session.channel.close(SecureChannel.ChannelError.protocolViolation)
                return
            }
            session.code = Self.comparisonCode(transcript: transcript, hostNonce: session.myNonce, joinerNonce: nonce)
            pairingStatus = .confirm(device: session.peerName, code: session.code!)

        case (.confirmed, .hostPairing), (.confirmed, .joinPairing):
            guard session.code != nil else {
                session.channel.close(SecureChannel.ChannelError.protocolViolation)
                return
            }
            session.confirmedThere = true
            if session.purpose == .hostPairing && session.confirmedHere { grant(to: session) }

        case (.grant(let key, let server), .joinPairing):
            // Only accept the key once the user has confirmed the codes match here.
            guard session.confirmedHere, session.confirmedThere, key.count == 32 else {
                session.channel.close(SecureChannel.ChannelError.protocolViolation)
                return
            }
            pairingSession = nil
            adoptGroupKey(key)
            // Pick up the group's sync server unless this device already uses one.
            if settings.serverURL == nil, let server, let url = Self.normalizedServerURL(server) {
                settings.serverURL = url.absoluteString
                serverURL = url
            }
            if let peerID = session.peerID {
                settings.peers[peerID] = settings.peers[peerID] ?? PeerRecord(name: session.peerName, platform: session.platform, cursor: 0)
            }
            saveSettings(immediately: true)
            pairingStatus = .paired(with: session.peerName)
            session.channel.close()
            stopBrowsingForPairing()
            settings.enabled = true
            restart()

        default:
            session.channel.close(SecureChannel.ChannelError.protocolViolation)
        }
    }

    private func handleHello(on session: Session) {
        guard let peerID = session.peerID else { return }
        switch session.purpose {
        case .hostPairing:
            break // Wait for the joiner's commitment.

        case .joinPairing:
            guard let transcript = session.channel.transcript else { return }
            session.myNonce = Self.randomNonce()
            send(.commit(Self.commitment(session.myNonce, transcript: transcript)), on: session)

        case .sync:
            // Two devices often dial each other at once. Keep exactly one
            // connection: the one dialed by the device with the smaller id.
            let duplicates = sessions.values.filter { $0 !== session && $0.purpose == .sync && $0.helloReceived && $0.peerID == peerID }
            if !duplicates.isEmpty {
                let all = duplicates + [session]
                let winner = all.first { initiator(of: $0) == min(store.deviceID, peerID) } ?? duplicates[0]
                for other in all where other !== winner { other.channel.close() }
                if winner !== session { return }
            }
            var record = settings.peers[peerID] ?? PeerRecord(name: session.peerName, platform: session.platform, cursor: 0)
            record.name = session.peerName
            record.platform = session.platform
            settings.peers[peerID] = record
            saveSettings()
            send(.request(since: record.cursor), on: session)
            refreshPeers()
        }
    }

    private func initiator(of session: Session) -> String {
        session.channel.isOutgoing ? store.deviceID : (session.peerID ?? "")
    }

    // MARK: - Pushing changes

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .milliseconds(300))
            guard !Swift.Task.isCancelled, let self else { return }
            for session in self.sessions.values where session.purpose == .sync && session.requested {
                if self.store.seq > session.sentCursor {
                    self.pushChanges(to: session, since: session.sentCursor)
                }
            }
        }
    }

    private func pushChanges(to session: Session, since: Int64) {
        let changes = store.changes(since: since)
        let chunkSize = 500
        var start = 0
        repeat {
            let chunk = Array(changes[start..<min(start + chunkSize, changes.count)])
            start += chunkSize
            let isLast = start >= changes.count
            let upTo = isLast ? store.seq : (chunk.last?.seq ?? store.seq)
            send(.changes(records: chunk, upTo: upTo), on: session)
        } while start < changes.count
        session.sentCursor = store.seq
    }

    // MARK: - Sync key (joining without being nearby)

    /// The group key as text, for joining from a device that's never on the
    /// same network (e.g. syncing only through a server). Anyone with it can
    /// join the group, so share it like a password.
    public var syncKey: String? {
        guard let key = settings.groupKey else { return nil }
        let base64 = key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "DBL1-" + base64
    }

    /// Joins the group a `syncKey` belongs to. Data on this device is kept and merged.
    @discardableResult
    public func join(syncKey text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("DBL1-") else { return false }
        var base64 = String(trimmed.dropFirst(5)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let key = Data(base64Encoded: base64), key.count == 32 else { return false }
        guard key != settings.groupKey else { return true }
        adoptGroupKey(key)
        settings.peers = [:]
        settings.enabled = true
        saveSettings(immediately: true)
        refreshPeers()
        restart()
        return true
    }

    /// Switches groups. Server cursors belong to a group, so they start over.
    private func adoptGroupKey(_ key: Data?) {
        if key != settings.groupKey {
            settings.serverPushed = nil
            settings.serverCursor = nil
        }
        settings.groupKey = key
    }

    // MARK: - Sync server

    static func normalizedServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Sets (or with nil/empty, removes) the sync server. Creates a sync group if
    /// this device doesn't have one yet. Throws if the address isn't a valid URL.
    public func setServer(_ text: String?) throws {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url: URL?
        if trimmed.isEmpty {
            url = nil
        } else {
            guard let parsed = Self.normalizedServerURL(trimmed) else { throw RelayClient.ServerError(status: 0, message: "Enter an address like https://sync.example.com") }
            url = parsed
        }
        guard url != serverURL else { return }
        stopRelay()
        serverURL = url
        settings.serverURL = url?.absoluteString
        settings.serverPushed = nil
        settings.serverCursor = nil
        serverLastSync = nil
        if url != nil { _ = ensureGroup() }
        saveSettings(immediately: true)
        if isRunning { startRelay() }
    }

    /// Checks that `text` points at a reachable Dabble sync server.
    public func testServer(_ text: String) async throws {
        guard let url = Self.normalizedServerURL(text) else { throw RelayClient.ServerError(status: 0, message: "Enter an address like https://sync.example.com") }
        let keys = RelayKeys(groupKey: settings.groupKey ?? Data(count: 32))
        try await RelayClient(baseURL: url, keys: keys).health()
    }

    @ObservationIgnored private var relayTask: Swift.Task<Void, Never>?
    @ObservationIgnored private var relayPushTask: Swift.Task<Void, Never>?

    private var relayClient: RelayClient? {
        guard settings.enabled, let key = settings.groupKey, let serverURL else { return nil }
        return RelayClient(baseURL: serverURL, keys: RelayKeys(groupKey: key))
    }

    private func stopRelay() {
        relayTask?.cancel()
        relayTask = nil
        relayPushTask?.cancel()
        relayPushTask = nil
        serverStatus = .off
    }

    /// Push, then long-poll for changes, forever, backing off on errors.
    private func startRelay() {
        guard relayTask == nil, let client = relayClient else { return }
        serverStatus = .connecting
        relayTask = Swift.Task { [weak self] in
            var backoff: Double = 2
            var wait = 0
            while !Swift.Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.relayPush(client)
                    try await self.relayPull(client, wait: wait)
                    try Swift.Task.checkCancellation()
                    self.serverStatus = .connected
                    backoff = 2
                    wait = 25
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    guard !Swift.Task.isCancelled else { return }
                    self.serverStatus = .error(error.localizedDescription)
                    try? await Swift.Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 60)
                    wait = 0
                }
            }
        }
    }

    private func scheduleRelayPush() {
        guard relayTask != nil, let client = relayClient else { return }
        relayPushTask?.cancel()
        relayPushTask = Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .seconds(1))
            guard let self, !Swift.Task.isCancelled else { return }
            do {
                try await self.relayPush(client)
            } catch {
                if !Swift.Task.isCancelled, !(error is CancellationError) { self.serverStatus = .error(error.localizedDescription) }
            }
        }
    }

    /// Uploads records changed since the last push. The server drops rows it
    /// already has a newer (or the same) version of.
    private func relayPush(_ client: RelayClient) async throws {
        while true {
            let since = settings.serverPushed ?? 0
            let batch = store.changes(since: since, limit: 300)
            guard let upTo = batch.last?.seq else { return }
            try await client.push(batch)
            try Swift.Task.checkCancellation()
            settings.serverPushed = max(settings.serverPushed ?? 0, upTo)
            serverLastSync = Date()
            saveSettings()
        }
    }

    private func relayPull(_ client: RelayClient, wait: Int) async throws {
        var wait = wait
        while true {
            let result = try await client.pull(since: settings.serverCursor ?? 0, wait: wait)
            try Swift.Task.checkCancellation()
            if !result.records.isEmpty {
                // What came from the server doesn't need to go back to it. If we
                // had nothing pending before merging, skip past the merge.
                let caughtUp = (settings.serverPushed ?? 0) >= store.seq
                store.merge(result.records)
                if caughtUp { settings.serverPushed = store.seq }
            }
            settings.serverCursor = result.cursor
            serverLastSync = Date()
            saveSettings()
            if !result.more { return }
            wait = 0
        }
    }

    // MARK: - Bookkeeping

    private func refreshPeers() {
        let connected = Set(sessions.values.filter { $0.purpose == .sync && $0.helloReceived }.compactMap(\.peerID))
        peers = settings.peers.map { id, record in
            Peer(id: id, name: record.name, platform: record.platform, isConnected: connected.contains(id), lastSync: record.lastSync)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lastSync = settings.peers.values.compactMap(\.lastSync).max()
    }

    private func saveSettings(immediately: Bool = false) {
        guard let settingsURL else { return }
        settingsSaveTask?.cancel()
        let write = { [settings] in
            if let data = try? JSONEncoder().encode(settings) {
                try? data.write(to: settingsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        if immediately {
            write()
        } else {
            settingsSaveTask = Swift.Task {
                try? await Swift.Task.sleep(for: .seconds(1))
                guard !Swift.Task.isCancelled else { return }
                write()
            }
        }
    }

    /// Flush settings to disk (call when the app is about to quit or go to the background).
    public func flush() {
        saveSettings(immediately: true)
    }
}
