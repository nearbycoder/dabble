import DabbleKit
import Foundation

/// A Model Context Protocol server on stdin/stdout exposing every agent tool.
///
/// It stays connected to the user's devices for as long as the agent runs, so
/// changes show up on their Mac and iPhone within a second or two. Only one
/// process can own the replica; a second `dabble mcp` forwards to the first.
@MainActor
final class MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let options: Options
    private var replica: Replica?
    private var control: ControlServer?
    private var signalSources: [DispatchSourceSignal] = []

    init(options: Options) {
        self.options = options
    }

    static let instructions = """
    Dabble is the user's to-do app (it works like Things 3). Start with `overview` or `list_items` to get ids; never invent ids. \
    `when` is the day the user plans to do something (today, this evening, tomorrow, a date, anytime, someday, inbox); \
    `deadline` is when it's due — don't confuse them. Prefer `trash` over `delete_permanently`, and ask before anything irreversible. \
    If a tool says dabble isn't connected, tell the user to open Dabble → Settings → Agents on their Mac and run the join command shown there.
    """

    func run() async -> Int32 {
        installSignalHandlers()
        await acquire()
        for await line in Self.stdinLines() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let message = try? JSONValue.parse(trimmed) else {
                send(["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = message.arrayValue {
                var responses: [JSONValue] = []
                for item in batch { if let response = await handle(item) { responses.append(response) } }
                if !responses.isEmpty { send(.array(responses)) }
            } else if let response = await handle(message) {
                send(response)
            }
        }
        await shutdown()
        return 0
    }

    /// Lines from stdin, read off the main thread.
    static func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
            thread.start()
        }
    }

    // MARK: - Owning the replica

    /// Becomes the owner of the replica, or a proxy to the process that is.
    private func acquire() async {
        let deadline = ContinuousClock.now + .seconds(15)
        while replica == nil {
            if let opened = try? Replica.tryOpen(home: options.home) {
                replica = opened
                if opened.sync.hasGroup { opened.sync.start() }
                let server = ControlServer(replica: opened)
                server.start()
                control = server
                log("dabble mcp: serving \(options.home.path) as “\(opened.sync.deviceName)”")
                return
            }
            if FileManager.default.fileExists(atPath: options.home.appendingPathComponent("control.json").path) {
                log("dabble mcp: another dabble mcp owns \(options.home.path); forwarding to it")
                return
            }
            if ContinuousClock.now > deadline { return }
            try? await Swift.Task.sleep(for: .milliseconds(200))
        }
    }

    private func shutdown() async {
        control?.stop()
        if let replica {
            await replica.flush()
            replica.close()
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { exit(0) }
                    Swift.Task { @MainActor in
                        await self.shutdown()
                        exit(0)
                    }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - JSON-RPC

    private func send(_ message: JSONValue) {
        FileHandle.standardOutput.write(Data((message.encoded() + "\n").utf8))
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func handle(_ message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.stringValue else { return nil } // a response or junk
        let id = message["id"]
        let params = message["params"]?.objectValue ?? [:]
        func result(_ value: JSONValue) -> JSONValue? {
            id.map { ["jsonrpc": "2.0", "id": $0, "result": value] }
        }
        func failure(_ code: Int, _ text: String) -> JSONValue? {
            id.map { ["jsonrpc": "2.0", "id": $0, "error": ["code": .number(Double(code)), "message": .string(text)]] }
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.supportedVersions[0]
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return result([
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "dabble", "title": "Dabble", "version": .string(DabbleCLI.version)],
                "instructions": .string(Self.instructions),
            ])
        case "server/discover":
            return result([
                "supportedVersions": .array(Self.supportedVersions.map { .string($0) }),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "dabble", "title": "Dabble", "version": .string(DabbleCLI.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": .array(AgentToolbox.tools.map(Self.describe))])
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = AgentToolbox.tool(named: name) else {
                return failure(-32602, "Unknown tool: \(params["name"]?.stringValue ?? "")")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            do {
                let value = try await call(tool, arguments)
                return result(["content": [["type": "text", "text": .string(value.encoded())]], "isError": false])
            } catch {
                let text = (error as? UsageError)?.message ?? error.localizedDescription
                return result(["content": [["type": "text", "text": .string(text)]], "isError": true])
            }
        case "resources/list":
            return result(["resources": []])
        case "resources/templates/list":
            return result(["resourceTemplates": []])
        case "prompts/list":
            return result(["prompts": []])
        default:
            if method.hasPrefix("notifications/") { return nil }
            return failure(-32601, "Method not found: \(method)")
        }
    }

    private func call(_ tool: AgentTool, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        if let replica {
            try replica.requireJoined(allowLocal: options.local || tool.name == "sync_status")
            return try replica.box.call(tool.name, arguments)
        }
        if let forwarded = try await ControlClient.call(home: options.home, tool: tool.name, arguments: arguments, local: options.local) {
            return forwarded
        }
        // The owner went away; take over.
        await acquire()
        guard let replica else { throw AgentError("dabble's data folder is busy. Try again in a moment.") }
        try replica.requireJoined(allowLocal: options.local || tool.name == "sync_status")
        return try replica.box.call(tool.name, arguments)
    }

    nonisolated static func describe(_ tool: AgentTool) -> JSONValue {
        let destructive = ["delete_permanently", "empty_trash"].contains(tool.name)
        return [
            "name": .string(tool.name),
            "title": .string(tool.name.replacingOccurrences(of: "_", with: " ").capitalized),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": [
                "readOnlyHint": .bool(tool.readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(tool.readOnly),
                "openWorldHint": false,
            ],
        ]
    }
}
