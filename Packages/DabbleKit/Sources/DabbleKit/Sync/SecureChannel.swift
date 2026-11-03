import CryptoKit
import Foundation
import Network

/// An encrypted, authenticated message pipe over a TCP connection.
///
/// Handshake: each side sends `version || nonce(32) || X25519 public key(32)`.
/// Both derive two directional ChaChaPoly keys with
/// `HKDF(ECDH shared secret || pre-shared key, salt: both hellos sorted)`.
/// The ECDH secret gives forward secrecy; mixing in the PSK means only devices
/// holding the sync group key can talk. A wrong key shows up as the first
/// message failing to decrypt. Pairing channels use a public PSK and are then
/// authenticated by the user comparing a code bound to `transcript`.
///
/// Frames are `UInt32 big-endian length || payload`. After the handshake the
/// payload is `ciphertext || tag`, with a per-direction counter as the nonce,
/// so frames can't be replayed, reordered or dropped without detection.
@MainActor
final class SecureChannel {
    enum ChannelError: LocalizedError {
        case authenticationFailed
        case protocolViolation
        case timedOut

        var errorDescription: String? {
            switch self {
            case .authenticationFailed: "The other device has a different key."
            case .protocolViolation: "The other device sent something unexpected."
            case .timedOut: "The connection timed out."
            }
        }
    }

    static let version: UInt8 = 1
    static let maxFrame = 64 * 1024 * 1024

    let connection: NWConnection
    let isOutgoing: Bool
    private let psk: SymmetricKey
    private let purpose: String
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let hello: Data
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var buffer = Data()
    private var closed = false
    private var receivedFirstMessage = false
    /// Hash of both handshake hellos. A man in the middle ends up with a
    /// different transcript on each side.
    private(set) var transcript: Data?

    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(connection: NWConnection, psk: SymmetricKey, purpose: String, outgoing: Bool) {
        self.connection = connection
        self.psk = psk
        self.purpose = purpose
        isOutgoing = outgoing
        var hello = Data([Self.version])
        hello.append(contentsOf: (0..<32).map { _ in UInt8.random(in: .min ... .max) })
        hello.append(privateKey.publicKey.rawRepresentation)
        self.hello = hello
    }

    var remoteDescription: String {
        "\(connection.endpoint)"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .seconds(15))
            guard let self, !self.closed, !self.receivedFirstMessage else { return }
            self.close(ChannelError.timedOut)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendFrame(hello)
            receive()
        case .failed(let error):
            close(error)
        case .waiting(let error):
            // Outgoing connections that can't reach the peer park in .waiting; give up.
            if isOutgoing { close(error) }
        case .cancelled:
            close(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                if let error {
                    self.close(error)
                } else if isComplete {
                    self.close(nil)
                } else if !self.closed {
                    self.receive()
                }
            }
        }
    }

    private func processBuffer() {
        while !closed, buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Self.maxFrame else {
                close(ChannelError.protocolViolation)
                return
            }
            guard buffer.count >= 4 + length else { return }
            let frame = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            handleFrame(frame)
        }
    }

    private func handleFrame(_ frame: Data) {
        guard let receiveKey else {
            completeHandshake(theirHello: frame)
            return
        }
        do {
            guard frame.count >= 16 else { throw ChannelError.protocolViolation }
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: frame.dropLast(16), tag: frame.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            receivedFirstMessage = true
            onMessage?(plaintext)
        } catch {
            close(receivedFirstMessage ? ChannelError.protocolViolation : ChannelError.authenticationFailed)
        }
    }

    private func completeHandshake(theirHello: Data) {
        guard theirHello.count == 65, theirHello.first == Self.version,
              let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirHello.suffix(32)),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: theirKey) else {
            close(ChannelError.protocolViolation)
            return
        }
        var material = shared.withUnsafeBytes { Data($0) }
        psk.withUnsafeBytes { material.append(contentsOf: $0) }
        let first = hello.lexicographicallyPrecedes(theirHello) ? hello : theirHello
        let second = first == hello ? theirHello : hello
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: first + second,
            info: Data("dabble/v1/\(purpose)".utf8),
            outputByteCount: 64
        )
        transcript = Data(SHA256.hash(data: first + second))
        let bytes = derived.withUnsafeBytes { Data($0) }
        let keyA = SymmetricKey(data: bytes.prefix(32))
        let keyB = SymmetricKey(data: bytes.suffix(32))
        let iAmFirst = first == hello
        sendKey = iAmFirst ? keyA : keyB
        receiveKey = iAmFirst ? keyB : keyA
        onReady?()
    }

    func send(_ plaintext: Data) {
        guard !closed, let sendKey else { return }
        do {
            let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
            sendCounter += 1
            sendFrame(box.ciphertext + box.tag)
        } catch {
            close(error)
        }
    }

    private func sendFrame(_ payload: Data) {
        var frame = Data(capacity: payload.count + 4)
        let length = UInt32(payload.count)
        frame.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.close(error) }
        })
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onClose = nil
        onReady = nil
        onMessage = nil
        handler?(error)
    }
}
