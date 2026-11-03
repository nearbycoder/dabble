import XCTest
@testable import DabbleKit

/// Two devices that never see each other on the network, syncing only through
/// the relay in `server/`, run as a real Node process.
@MainActor
final class RelayTests: XCTestCase {
    private var server: Process?
    private var dataDir: URL?
    private var baseURL = ""

    override func setUp() async throws {
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        let node = (searchPath + ["/opt/homebrew/bin/node", "/usr/local/bin/node"]).first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node else { throw XCTSkip("node isn't installed") }
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/server.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { throw XCTSkip("server/server.mjs not found") }

        let port = Int.random(in: 20_000...40_000)
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("dabble-relay-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path]
        process.environment = ["PORT": String(port), "HOST": "127.0.0.1", "DATA_DIR": dataDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        self.dataDir = dataDir
        baseURL = "http://127.0.0.1:\(port)"

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: URL(string: "\(baseURL)/v1/health")!),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("relay didn't start")
    }

    override func tearDown() async throws {
        server?.terminate()
        server?.waitUntilExit()
        if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
    }

    private func waitUntil(_ timeout: TimeInterval = 15, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out", line: line); throw TimedOut() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeDevice(_ name: String) -> (DabbleStore, SyncEngine) {
        let store = DabbleStore(directory: nil, deviceID: name)
        let engine = SyncEngine(store: store, directory: nil, port: 0, discovery: false)
        engine.deviceName = name
        return (store, engine)
    }

    func testDevicesSyncThroughTheServerOnly() async throws {
        let (homeStore, home) = makeDevice("home")
        let (workStore, work) = makeDevice("work")
        let early = homeStore.addToDo("Made before the server was set up", in: .today)

        // Home sets up the server (creating a group); work joins with the sync key.
        try await home.testServer(baseURL)
        try home.setServer(baseURL)
        home.start()
        let key = try XCTUnwrap(home.syncKey)
        XCTAssertTrue(work.join(syncKey: key))
        try work.setServer(baseURL)
        work.start()

        try await waitUntil { workStore.todo(early.id) != nil }
        XCTAssertEqual(work.serverStatus, .connected)

        // Live changes travel both ways through long polling.
        let fromWork = workStore.addToDo("Added at work")
        try await waitUntil { homeStore.todo(fromWork.id) != nil }
        homeStore.setStatus([fromWork.id], .completed)
        workStore.update(ToDo.self, early.id) { $0.notes = "notes from work" }
        try await waitUntil {
            workStore.todo(fromWork.id)?.status == .completed && homeStore.todo(early.id)?.notes == "notes from work"
        }

        // Concurrent edits to the same field converge.
        homeStore.update(ToDo.self, early.id) { $0.title = "Home title" }
        workStore.update(ToDo.self, early.id) { $0.title = "Work title" }
        try await waitUntil { homeStore.todo(early.id)?.title == workStore.todo(early.id)?.title }
        XCTAssertEqual(homeStore.records[early.id]?.fields, workStore.records[early.id]?.fields)
        XCTAssertTrue(home.peers.isEmpty, "no LAN connection was involved")

        home.stop()
        work.stop()
    }

    func testServerNeverSeesPlaintext() async throws {
        let (store, engine) = makeDevice("solo")
        store.addToDo("Top secret surprise party")
        try engine.setServer(baseURL)
        engine.start()
        try await waitUntil { engine.serverStatus == .connected }
        engine.stop()
        server?.terminate()
        server?.waitUntilExit()

        var dump = Data()
        for file in (try? FileManager.default.contentsOfDirectory(at: dataDir!, includingPropertiesForKeys: nil)) ?? [] {
            dump.append((try? Data(contentsOf: file)) ?? Data())
        }
        XCTAssertFalse(dump.isEmpty)
        XCTAssertNil(dump.range(of: Data("surprise".utf8)))
    }

    func testRejectsBadAddressesAndNonDabbleServers() async throws {
        let (_, engine) = makeDevice("x")
        XCTAssertThrowsError(try engine.setServer("not a url at all ::"))
        XCTAssertEqual(SyncEngine.normalizedServerURL("sync.example.com/")?.absoluteString, "https://sync.example.com")
        do {
            try await engine.testServer("http://127.0.0.1:1")
            XCTFail("should fail")
        } catch {}
    }

    func testSortableHLCMatchesOrdering() {
        let a = HLC(wall: 999, counter: 12, node: "b")
        let b = HLC(wall: 1_000, counter: 0, node: "a")
        let c = HLC(wall: 1_000, counter: 2, node: "a")
        XCTAssertLessThan(a.sortable, b.sortable)
        XCTAssertLessThan(b.sortable, c.sortable)
    }
}
