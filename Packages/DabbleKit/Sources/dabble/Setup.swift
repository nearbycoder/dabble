import DabbleKit
import Foundation

/// Joining the user's devices, and other one-time setup.
@MainActor
enum Setup {
    static func join(_ arguments: [String], _ options: Options) async throws -> Int32 {
        var key: String?
        var server: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--server", index + 1 < arguments.count {
                server = arguments[index + 1]
                index += 1
            } else {
                key = arguments[index]
            }
            index += 1
        }
        guard let key else { throw UsageError("Usage: dabble join <sync key> [--server URL]\nCopy the key from Dabble → Settings → Agents (or Settings → Sync → Advanced).") }
        let replica = try await ownReplica(options)
        defer { replica.close() }
        guard replica.sync.join(syncKey: key) else { throw UsageError("That doesn't look like a Dabble sync key. It starts with DBL1-.") }
        if let server { try replica.sync.setServer(server) }
        print("Joined your sync group as “\(replica.sync.deviceName)”. Looking for your devices…")
        if await replica.sync.waitForSync(timeout: .seconds(10)) {
            let count = replica.store.snapshot.todos.values.filter { !$0.isTrashed && $0.isOpen }.count
            print("Synced. \(count) open to-do\(count == 1 ? "" : "s") here now.")
        } else {
            print("None of your devices answered yet. Keep Dabble open on your Mac (or set a sync server), then run `dabble status`.")
        }
        await replica.flush()
        return 0
    }

    static func pair(_ arguments: [String], _ options: Options) async throws -> Int32 {
        let replica = try await ownReplica(options)
        defer { replica.close() }
        let sync = replica.sync
        var host: SyncEngine.PairingHost?
        if let flag = arguments.firstIndex(of: "--address"), flag + 1 < arguments.count {
            guard let (name, port) = SyncEngine.parseAddress(arguments[flag + 1]) else { throw UsageError("Use --address host:port.") }
            host = .address(name, port: port)
        } else {
            print("Looking for devices ready to pair… (on your Mac or iPhone: Settings → Sync → Pair New Device)")
            sync.startBrowsingForPairing()
            let deadline = ContinuousClock.now + .seconds(20)
            while sync.pairingHosts.isEmpty && ContinuousClock.now < deadline { try await Swift.Task.sleep(for: .milliseconds(200)) }
            try await Swift.Task.sleep(for: .milliseconds(800))
            let hosts = sync.pairingHosts
            guard !hosts.isEmpty else { throw UsageError("No devices are ready to pair. Open Settings → Sync → Pair New Device on one, or use `dabble join <sync key>`.") }
            if hosts.count == 1 {
                host = hosts[0]
            } else {
                for (number, candidate) in hosts.enumerated() { print("  \(number + 1). \(candidate.name)") }
                let answer = await prompt("Which one? [1-\(hosts.count)] ")
                guard let choice = Int(answer), (1...hosts.count).contains(choice) else { throw UsageError("Canceled.") }
                host = hosts[choice - 1]
            }
        }
        sync.join(host!)
        while true {
            switch sync.pairingStatus {
            case .confirm(let device, let code):
                print("\nBoth devices now show a code. Check that “\(device)” shows:\n\n      \(code)\n")
                let answer = await prompt("Do the codes match? [y/N] ")
                if answer.lowercased().hasPrefix("y") {
                    sync.confirmPairing()
                    print("Now tap Codes Match on “\(device)”…")
                } else {
                    sync.rejectPairing()
                    throw UsageError("Pairing canceled.")
                }
                while case .waiting = sync.pairingStatus { try await Swift.Task.sleep(for: .milliseconds(150)) }
            case .paired(let device):
                print("Paired with \(device). Syncing…")
                await sync.waitForSync(timeout: .seconds(10))
                let count = replica.store.snapshot.todos.values.filter { !$0.isTrashed && $0.isOpen }.count
                print("Done. \(count) open to-do\(count == 1 ? "" : "s") here now.")
                await replica.flush()
                return 0
            case .failed(let message):
                throw UsageError("Pairing failed: \(message)")
            default:
                try await Swift.Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Prints the sync key (creating a group if needed) so other devices can join.
    static func key(_ options: Options) async throws -> Int32 {
        let replica = try await ownReplica(options)
        defer { replica.close() }
        replica.sync.createGroupIfNeeded()
        FileHandle.standardError.write(Data("Anyone with this key can read and change your to-dos. Paste it only into your own devices.\n".utf8))
        print(replica.sync.syncKey ?? "")
        return 0
    }

    static func leave(_ options: Options) async throws -> Int32 {
        let replica = try await ownReplica(options)
        defer { replica.close() }
        replica.sync.leaveGroup()
        print("Left the sync group. This computer's copy stays in \(options.home.path).")
        return 0
    }

    static func rename(_ arguments: [String], _ options: Options) async throws -> Int32 {
        let name = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let replica = try await ownReplica(options)
        defer { replica.close() }
        if name.isEmpty {
            print(replica.sync.deviceName)
        } else {
            replica.sync.deviceName = name
            print("Your devices will see this agent as “\(name)”.")
        }
        return 0
    }

    static func server(_ arguments: [String], _ options: Options) async throws -> Int32 {
        let replica = try await ownReplica(options)
        defer { replica.close() }
        guard let address = arguments.first else {
            print(replica.sync.serverURL?.absoluteString ?? "No sync server.")
            return 0
        }
        if ["off", "none", "remove"].contains(address.lowercased()) {
            try replica.sync.setServer(nil)
            print("Stopped using a sync server.")
        } else {
            try await replica.sync.testServer(address)
            try replica.sync.setServer(address)
            print("Using \(replica.sync.serverURL!.absoluteString).")
        }
        return 0
    }

    static func skill(_ arguments: [String]) throws -> Int32 {
        guard arguments.first == "install" else {
            print(AgentSkill.markdown)
            return 0
        }
        var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true)
        if let flag = arguments.firstIndex(of: "--dir"), flag + 1 < arguments.count {
            directory = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        let folder = directory.appendingPathComponent(AgentSkill.name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try AgentSkill.markdown.write(to: file, atomically: true, encoding: .utf8)
        print("Installed the Dabble skill to \(file.path)")
        return 0
    }

    /// Setup needs the replica itself, not a running `dabble mcp`.
    private static func ownReplica(_ options: Options) async throws -> Replica {
        if let replica = try Replica.tryOpen(home: options.home) { return replica }
        if FileManager.default.fileExists(atPath: options.home.appendingPathComponent("control.json").path) {
            throw UsageError("`dabble mcp` is running (probably inside your AI app) and holds \(options.home.path). Quit that app, run this again, then reopen it.")
        }
        return try await Replica.open(home: options.home)
    }

    private static func prompt(_ text: String) async -> String {
        FileHandle.standardOutput.write(Data(text.utf8))
        return await Swift.Task.detached { readLine() ?? "" }.value.trimmingCharacters(in: .whitespaces)
    }
}
