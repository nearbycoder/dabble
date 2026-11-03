import DabbleKit
import Foundation
import Network

/// This computer's copy of Dabble, owned by one process at a time.
@MainActor
final class Replica {
    let home: URL
    let store: DabbleStore
    let sync: SyncEngine
    let box: AgentToolbox
    private var lockDescriptor: Int32

    private init(home: URL, lock: Int32) {
        self.home = home
        lockDescriptor = lock
        store = DabbleStore(directory: home)
        sync = SyncEngine(store: store, directory: home, port: 0, discovery: true, platform: "Agent")
        box = AgentToolbox(store: store, sync: sync)
        if sync.deviceName == Host.current().localizedName ?? "" || sync.deviceName.isEmpty {
            sync.deviceName = "Agent on \(Host.current().localizedName ?? "this Mac")"
        }
    }

    /// Opens the replica, waiting up to `timeout` if another `dabble` holds it.
    static func open(home: URL, timeout: Duration = .seconds(15)) async throws -> Replica {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let replica = try tryOpen(home: home) { return replica }
            if ContinuousClock.now > deadline {
                throw UsageError("Another dabble process is using \(home.path). Try again in a moment.")
            }
            try await Swift.Task.sleep(for: .milliseconds(200))
        }
    }

    /// Nil if another process holds the lock.
    static func tryOpen(home: URL) throws -> Replica? {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(home.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw UsageError("Can't open \(home.path)/lock: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return Replica(home: home, lock: descriptor)
    }

    func requireJoined(allowLocal: Bool) throws {
        guard !sync.hasGroup, !allowLocal else { return }
        throw UsageError("""
        dabble isn't connected to your devices yet, so it can't see your to-dos.
        Set it up once, either way:
          • In Dabble on your Mac: Settings → Agents, then run the command it shows (dabble join DBL1-…).
          • Or run `dabble pair` and compare the code with Settings → Sync → Pair New Device on a nearby device.
        (Use --local to work with a separate list on this computer only.)
        """)
    }

    /// Connects to the user's devices and waits until caught up (or the timeout).
    func catchUp(timeout: Duration) async -> Bool {
        guard sync.hasGroup else { return false }
        sync.start()
        return await sync.waitForSync(timeout: timeout)
    }

    /// Sends pending changes to whoever is connected and saves.
    func flush() async {
        store.saveNow()
        guard sync.isRunning else { return }
        await sync.pushNow()
        // Give the network a moment to deliver before the process exits.
        try? await Swift.Task.sleep(for: .milliseconds(700))
    }

    func close() {
        store.saveNow()
        sync.flush()
        sync.stop()
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }
}

// MARK: - Forwarding to a running `dabble mcp`

/// Lets other `dabble` processes run tools through the process that owns the
/// replica, over a loopback socket guarded by a random token.
@MainActor
final class ControlServer {
    private let replica: Replica
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private var file: URL { replica.home.appendingPathComponent("control.json") }

    init(replica: Replica) {
        self.replica = replica
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state, let port = listener.port?.rawValue { self?.writeFile(port: port) }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(at: file)
    }

    private func writeFile(port: UInt16) {
        let info: JSONValue = ["port": .number(Double(port)), "token": .string(token), "pid": .number(Double(getpid()))]
        FileManager.default.createFile(atPath: file.path, contents: Data(info.encoded().utf8), attributes: [.posixPermissions: 0o600])
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        LineIO.readLine(connection) { [weak self] line in
            guard let self, let line, let request = try? JSONValue.parse(line), request["token"]?.stringValue == self.token,
                  let tool = request["tool"]?.stringValue else {
                connection.cancel()
                return
            }
            let response: JSONValue
            do {
                try self.replica.requireJoined(allowLocal: tool == "sync_status" || request["local"] == true)
                response = ["ok": true, "result": try self.replica.box.call(tool, request["arguments"]?.objectValue ?? [:])]
            } catch let error as UsageError {
                response = ["ok": false, "error": .string(error.message)]
            } catch {
                response = ["ok": false, "error": .string(error.localizedDescription)]
            }
            LineIO.write(response.encoded() + "\n", to: connection) { connection.cancel() }
        }
    }
}

enum ControlClient {
    /// Runs a tool in the process that owns the replica, if one is running.
    @MainActor
    static func call(home: URL, tool: String, arguments: [String: JSONValue], local: Bool = false) async throws -> JSONValue? {
        let file = home.appendingPathComponent("control.json")
        guard let data = try? Data(contentsOf: file), let info = try? JSONDecoder().decode(JSONValue.self, from: data),
              let port = info["port"].flatMap({ if case .number(let n) = $0 { UInt16(n) } else { nil } }),
              let token = info["token"]?.stringValue,
              case .number(let pid)? = info["pid"], kill(pid_t(pid), 0) == 0 else { return nil }

        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let request: JSONValue = ["token": .string(token), "tool": .string(tool), "arguments": .object(arguments), "local": .bool(local)]
        let line: String? = await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ value: String?) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        LineIO.write(request.encoded() + "\n", to: connection) {
                            LineIO.readLine(connection) { finish($0) }
                        }
                    case .failed, .waiting, .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { finish(nil) }
        }
        guard let line, let response = try? JSONValue.parse(line) else { return nil }
        if response["ok"] == true { return response["result"] ?? .null }
        throw AgentError(response["error"]?.stringValue ?? "The running dabble mcp couldn't run that.")
    }
}

/// Newline-delimited messages over an NWConnection.
enum LineIO {
    static func write(_ text: String, to connection: NWConnection, then: @escaping @MainActor () -> Void) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            MainActor.assumeIsolated { then() }
        })
    }

    static func readLine(_ connection: NWConnection, buffer: Data = Data(), completion: @escaping @MainActor (String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let newline = buffer.firstIndex(of: 0x0A) {
                    completion(String(decoding: buffer[..<newline], as: UTF8.self))
                } else if isComplete || error != nil || buffer.count > 64 << 20 {
                    completion(buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self))
                } else {
                    readLine(connection, buffer: buffer, completion: completion)
                }
            }
        }
    }
}
