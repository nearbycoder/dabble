import Foundation
import Observation

/// When completed items leave their lists for the Logbook.
public enum LogbookPolicy: String, Codable, Sendable, CaseIterable {
    /// A couple of seconds after you check them off.
    case immediately
    /// At the end of the day they were completed.
    case daily
}

/// The single source of truth for one device's data.
///
/// Every change goes through `write(_:kind:_:)`, which stamps changed fields
/// with a fresh HLC and bumps the local sequence number. The sync engine reads
/// changes by sequence number and merges what peers send with `merge(_:)`.
@MainActor
@Observable
public final class DabbleStore {
    public private(set) var records: [UUID: Record] = [:]
    public private(set) var revision = 0
    public private(set) var seq: Int64 = 0
    public let deviceID: String

    /// Completed to-dos stay visible in their list until they are "logged".
    public var logbookPolicy: LogbookPolicy = .immediately {
        didSet { revision += 1 }
    }
    /// Completed recently enough that `.immediately` should still show them.
    public private(set) var recentlyCompleted: Set<UUID> = []

    @ObservationIgnored public weak var undoManager: UndoManager?
    @ObservationIgnored private var clock: HybridClock
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Swift.Task<Void, Never>?
    @ObservationIgnored private var logTask: Swift.Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: @MainActor (ChangeOrigin) -> Void] = [:]
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var pendingOrigin: ChangeOrigin?
    @ObservationIgnored private var cachedSnapshot: (revision: Int, snapshot: Snapshot)?

    public enum ChangeOrigin: Sendable {
        case local
        case remote
    }

    private struct File: Codable {
        var version = 1
        var deviceID: String
        var seq: Int64
        var clock: HLC
        var records: [Record]
    }

    /// Opens (or creates) the store in `directory`. Pass nil for an in-memory store.
    public init(directory: URL?, deviceID: String? = nil) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("dabble.json")
        } else {
            fileURL = nil
        }

        if let fileURL, let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            self.deviceID = file.deviceID
            seq = file.seq
            clock = HybridClock(node: file.deviceID, last: file.clock)
            records = Dictionary(file.records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            let id = deviceID ?? Self.makeDeviceID()
            self.deviceID = id
            clock = HybridClock(node: id)
        }
    }

    public nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dabble", isDirectory: true)
    }

    private static func makeDeviceID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    // MARK: - Observing

    /// Calls `handler` after every change, once per batch.
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (ChangeOrigin) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    /// Groups writes so observers and the save run once.
    public func batch<T>(_ body: () throws -> T) rethrows -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0, let origin = pendingOrigin {
                pendingOrigin = nil
                notify(origin)
            }
        }
        return try body()
    }

    private func didChange(_ origin: ChangeOrigin) {
        revision += 1
        scheduleSave()
        if batchDepth > 0 {
            if pendingOrigin != .local { pendingOrigin = origin }
        } else {
            notify(origin)
        }
    }

    private func notify(_ origin: ChangeOrigin) {
        for observer in observers.values { observer(origin) }
    }

    // MARK: - Reading

    /// All live (non-purged) objects, typed and indexed. Cached per revision.
    public var snapshot: Snapshot {
        if let cachedSnapshot, cachedSnapshot.revision == revision { return cachedSnapshot.snapshot }
        let snapshot = Snapshot(records: records.values)
        cachedSnapshot = (revision, snapshot)
        return snapshot
    }

    /// List queries for the given day.
    public func lists(today: Day = .today) -> Lists {
        let keep: Set<UUID>
        switch logbookPolicy {
        case .immediately:
            keep = recentlyCompleted
        case .daily:
            keep = Set(snapshot.todos.values.filter { !$0.isOpen && $0.completionDay() == today }.map(\.id)
                + snapshot.projects.values.filter { !$0.isOpen && $0.completionDay() == today }.map(\.id))
        }
        return Lists(snapshot: snapshot, today: today, keep: keep.union(recentlyCompleted))
    }

    public func entity<E: Entity>(_ type: E.Type, _ id: UUID) -> E? {
        guard let record = records[id], record.kind == E.kind, !record.values.bool(Key.purged) else { return nil }
        return E(record: record)
    }

    public func todo(_ id: UUID) -> ToDo? { entity(ToDo.self, id) }
    public func project(_ id: UUID) -> Project? { entity(Project.self, id) }
    public func area(_ id: UUID) -> Area? { entity(Area.self, id) }
    public func heading(_ id: UUID) -> Heading? { entity(Heading.self, id) }
    public func tag(_ id: UUID) -> Tag? { entity(Tag.self, id) }

    // MARK: - Writing

    /// Writes field values, stamping only those that differ from what's stored.
    public func write(_ id: UUID, kind: Kind, _ values: [String: Value], undoable: Bool = true) {
        var record = records[id] ?? Record(id: id, kind: kind)
        guard record.kind == kind else { return }
        var previous: [String: Value] = [:]
        for (key, value) in values where record.fields[key]?.v != value {
            previous[key] = record.fields[key]?.v ?? .null
            record.fields[key] = Field(value, clock.now())
        }
        guard !previous.isEmpty else { return }
        if records[id] == nil {
            record.fields[Key.createdAt] = Field(.number(Date().timeIntervalSince1970), clock.now())
        }
        seq += 1
        record.seq = seq
        records[id] = record

        if undoable, let undoManager {
            undoManager.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    store.write(id, kind: kind, previous)
                }
            }
        }
        didChange(.local)
    }

    /// Saves an entity, writing only the fields that changed.
    public func save<E: Entity>(_ entity: E) {
        write(entity.id, kind: E.kind, entity.values)
    }

    /// Loads, mutates and saves an entity in one go.
    public func update<E: Entity>(_ type: E.Type, _ id: UUID, _ body: (inout E) -> Void) {
        guard var entity = entity(type, id) else { return }
        body(&entity)
        save(entity)
    }

    // MARK: - Sync

    /// Full records changed locally after `since`, oldest first.
    public func changes(since: Int64, limit: Int = .max) -> [Record] {
        let changed = records.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
        return Array(changed.prefix(limit))
    }

    /// Merges records from a peer. Returns how many records changed.
    @discardableResult
    public func merge(_ incoming: [Record]) -> Int {
        var changed = 0
        for remote in incoming {
            for field in remote.fields.values { clock.observe(field.t) }
            var local = records[remote.id] ?? Record(id: remote.id, kind: remote.kind)
            guard local.kind == remote.kind else { continue }
            if local.merge(remote) {
                seq += 1
                local.seq = seq
                records[remote.id] = local
                changed += 1
            }
        }
        if changed > 0 { didChange(.remote) }
        return changed
    }

    // MARK: - Logbook timing

    func noteCompleted(_ id: UUID) {
        recentlyCompleted.insert(id)
        logTask?.cancel()
        logTask = Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .seconds(2.5))
            guard !Swift.Task.isCancelled else { return }
            self?.recentlyCompleted.removeAll()
            self?.revision += 1
        }
    }

    /// Moves recently completed items to the Logbook right away.
    public func logCompleted() {
        recentlyCompleted.removeAll()
        revision += 1
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .milliseconds(400))
            guard !Swift.Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the store to disk immediately.
    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        let file = File(deviceID: deviceID, seq: seq, clock: clock.last, records: Array(records.values))
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data("Dabble: failed to save store: \(error)\n".utf8))
        }
    }

    /// The store's contents as JSON, for backups.
    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Array(records.values).sorted { $0.seq < $1.seq })
    }

    /// Merges a backup produced by `exportData()`.
    public func importData(_ data: Data) throws {
        let imported = try JSONDecoder().decode([Record].self, from: data)
        merge(imported)
    }
}
