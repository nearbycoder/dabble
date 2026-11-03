import XCTest
@testable import DabbleKit

/// End-to-end sync between two in-process "devices" over real TCP on loopback.
@MainActor
final class SyncTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 10, line: UInt = #line, _ condition: () -> Bool) async throws {
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

    func testPairingThenBidirectionalSync() async throws {
        let (macStore, mac) = makeDevice("mac")
        let (phoneStore, phone) = makeDevice("phone")
        let existing = macStore.addToDo("Already on the Mac", in: .today)
        let phoneOnly = phoneStore.addToDo("Made on the phone before pairing")

        // Pair: the Mac waits, the phone joins, both show a code to compare.
        mac.startHostingPairing()
        try await waitUntil { mac.pairingPort != nil }
        XCTAssertEqual(mac.pairingStatus, .hosting)
        let host = SyncEngine.PairingHost.address("127.0.0.1", port: mac.pairingPort!)

        // First attempt: the user says the codes don't match.
        phone.join(host)
        try await waitUntil { if case .confirm = phone.pairingStatus { true } else { false } }
        phone.rejectPairing()
        try await waitUntil { mac.pairingStatus == .hosting }
        XCTAssertFalse(phone.hasGroup)

        // Second attempt: codes match and both sides confirm.
        phone.join(host)
        try await waitUntil {
            if case .confirm = phone.pairingStatus, case .confirm = mac.pairingStatus { true } else { false }
        }
        guard case .confirm(let macSees, let macCode) = mac.pairingStatus,
              case .confirm(let phoneSees, let phoneCode) = phone.pairingStatus else { return XCTFail() }
        XCTAssertEqual(macCode, phoneCode)
        XCTAssertEqual(macSees, "phone")
        XCTAssertEqual(phoneSees, "mac")

        phone.confirmPairing()
        try await waitUntil { phone.pairingStatus == .waiting(device: "mac") }
        XCTAssertFalse(phone.hasGroup, "no key until both sides confirm")
        mac.confirmPairing()
        try await waitUntil { phone.hasGroup }
        XCTAssertEqual(phone.groupID, mac.groupID)
        XCTAssertEqual(mac.pairingStatus, .paired(with: "phone"))
        XCTAssertEqual(phone.pairingStatus, .paired(with: "mac"))

        // Connect over a manual address, as you would over a VPN.
        mac.start()
        phone.start()
        try await waitUntil { mac.listenerPort != nil }
        phone.addManualPeer("127.0.0.1:\(mac.listenerPort!)")

        try await waitUntil { phoneStore.todo(existing.id) != nil && macStore.todo(phoneOnly.id) != nil }
        XCTAssertEqual(phoneStore.todo(existing.id)?.title, "Already on the Mac")
        XCTAssertTrue(mac.peers.contains { $0.id == "phone" && $0.isConnected })

        // Live edits keep flowing both ways while connected.
        phoneStore.update(ToDo.self, existing.id) { $0.notes = "edited on phone" }
        macStore.setStatus([phoneOnly.id], .completed)
        try await waitUntil {
            macStore.todo(existing.id)?.notes == "edited on phone" && phoneStore.todo(phoneOnly.id)?.status == .completed
        }

        // Concurrent edits to different fields both survive; same field converges.
        macStore.update(ToDo.self, existing.id) { $0.title = "Mac title" }
        phoneStore.update(ToDo.self, existing.id) { $0.title = "Phone title" }
        try await waitUntil { macStore.todo(existing.id)?.title == phoneStore.todo(existing.id)?.title }
        XCTAssertEqual(macStore.records[existing.id]?.fields, phoneStore.records[existing.id]?.fields)

        mac.stop()
        phone.stop()
    }

    func testComparisonCodeDependsOnTranscriptAndBothNonces() {
        let t = Data(repeating: 1, count: 32), a = Data(repeating: 2, count: 32), b = Data(repeating: 3, count: 32)
        let code = SyncEngine.comparisonCode(transcript: t, hostNonce: a, joinerNonce: b)
        XCTAssertEqual(code.count, 7)
        XCTAssertNotEqual(code, SyncEngine.comparisonCode(transcript: Data(repeating: 9, count: 32), hostNonce: a, joinerNonce: b))
        XCTAssertNotEqual(code, SyncEngine.comparisonCode(transcript: t, hostNonce: b, joinerNonce: a))
    }

    func testDevicesWithDifferentKeysCannotSync() async throws {
        let (aStore, a) = makeDevice("a")
        let (bStore, b) = makeDevice("b")
        a.setGroupKey(Data(repeating: 1, count: 32))
        b.setGroupKey(Data(repeating: 2, count: 32))
        a.start()
        b.start()
        try await waitUntil { a.listenerPort != nil }
        aStore.addToDo("Secret")
        b.addManualPeer("127.0.0.1:\(a.listenerPort!)")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(bStore.snapshot.todos.isEmpty)
        XCTAssertFalse(a.peers.contains { $0.isConnected })
        a.stop()
        b.stop()
    }

    func testLargeInitialSyncIsChunked() async throws {
        let (aStore, a) = makeDevice("a")
        let (bStore, b) = makeDevice("b")
        let key = Data(repeating: 7, count: 32)
        a.setGroupKey(key)
        b.setGroupKey(key)
        aStore.batch { for i in 0..<1_234 { aStore.addToDo("Item \(i)") } }
        a.start()
        b.start()
        try await waitUntil { a.listenerPort != nil }
        b.addManualPeer("127.0.0.1:\(a.listenerPort!)")
        try await waitUntil(20) { bStore.snapshot.todos.count == 1_234 }
        a.stop()
        b.stop()
    }
}

struct TimedOut: Error {}
