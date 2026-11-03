import Foundation

/// A typed view over a `Record`.
///
/// Entities are value snapshots: change their properties, then hand them to
/// `DabbleStore.save(_:)`, which stamps only the fields that actually changed.
public protocol Entity: Identifiable, Hashable, Sendable {
    static var kind: Kind { get }
    var id: UUID { get }
    var values: [String: Value] { get set }
    init(id: UUID, values: [String: Value])
}

public extension Entity {
    init(record: Record) {
        self.init(id: record.id, values: record.values)
    }

    var isTrashed: Bool {
        get { values.bool(Key.trashed) }
        set { values[Key.trashed] = .bool(newValue) }
    }

    var isPurged: Bool { values.bool(Key.purged) }

    var index: Double {
        get { values.double(Key.index) ?? 0 }
        set { values[Key.index] = .number(newValue) }
    }

    var createdAt: Date {
        Date(timeIntervalSince1970: values.double(Key.createdAt) ?? 0)
    }
}

/// Field names. Changing one breaks sync with older versions, so don't.
public enum Key {
    public static let title = "title"
    public static let notes = "notes"
    public static let status = "status"
    public static let completedAt = "completedAt"
    public static let start = "start"
    public static let startDate = "startDate"
    public static let evening = "evening"
    public static let deadline = "deadline"
    public static let reminder = "reminder"
    public static let tags = "tags"
    public static let area = "area"
    public static let project = "project"
    public static let heading = "heading"
    public static let index = "index"
    public static let todayIndex = "todayIndex"
    public static let trashed = "trashed"
    public static let purged = "purged"
    public static let createdAt = "createdAt"
    public static let repeatRule = "repeat"
    public static let repeatSeries = "repeatSeries"
    public static let parent = "parent"
    public static let shortcut = "shortcut"
    public static let todo = "todo"
    public static let done = "done"
    public static let archived = "archived"
}

public enum Status: String, Codable, Sendable, CaseIterable {
    case open
    case completed
    case canceled
}

/// Where a to-do or project lives on the "when" axis.
public enum Start: String, Codable, Sendable, CaseIterable {
    /// Not yet processed. Only loose to-dos can be in the inbox.
    case inbox
    /// Actionable now, or from `startDate` on.
    case anytime
    /// Parked until the user decides otherwise.
    case someday
}

/// Shared by to-dos and projects.
public protocol Schedulable: Entity {}

public extension Schedulable {
    var title: String {
        get { values.string(Key.title) }
        set { values[Key.title] = .string(newValue) }
    }

    var notes: String {
        get { values.string(Key.notes) }
        set { values[Key.notes] = .string(newValue) }
    }

    var status: Status {
        get { values.optString(Key.status).flatMap(Status.init(rawValue:)) ?? .open }
        set { values[Key.status] = .string(newValue.rawValue) }
    }

    var isOpen: Bool { status == .open }

    var completedAt: Date? {
        get { values.double(Key.completedAt).map { Date(timeIntervalSince1970: $0) } }
        set { values[Key.completedAt] = newValue.map { .number($0.timeIntervalSince1970) } ?? .null }
    }

    var start: Start {
        get { values.optString(Key.start).flatMap(Start.init(rawValue:)) ?? .anytime }
        set { values[Key.start] = .string(newValue.rawValue) }
    }

    var startDate: Day? {
        get { values.day(Key.startDate) }
        set { values[Key.startDate] = newValue.map { .string($0.description) } ?? .null }
    }

    var isEvening: Bool {
        get { values.bool(Key.evening) }
        set { values[Key.evening] = .bool(newValue) }
    }

    var deadline: Day? {
        get { values.day(Key.deadline) }
        set { values[Key.deadline] = newValue.map { .string($0.description) } ?? .null }
    }

    /// Time of day for a reminder on `startDate`, as minutes after midnight.
    var reminder: Int? {
        get { values.double(Key.reminder).map { Int($0) } }
        set { values[Key.reminder] = newValue.map { .number(Double($0)) } ?? .null }
    }

    var tagIDs: [UUID] {
        get { values.uuids(Key.tags) }
        set { values[Key.tags] = .list(newValue.map(\.uuidString)) }
    }

    var areaID: UUID? {
        get { values.uuid(Key.area) }
        set { values[Key.area] = newValue.map { .string($0.uuidString) } ?? .null }
    }

    var todayIndex: Double {
        get { values.double(Key.todayIndex) ?? 0 }
        set { values[Key.todayIndex] = .number(newValue) }
    }

    /// Scheduled for today (or overdue), i.e. shows up in Today.
    func isScheduled(onOrBefore day: Day) -> Bool {
        guard start != .inbox, let startDate else { return false }
        return startDate <= day
    }

    /// The day this was completed or canceled, if it was.
    func completionDay(calendar: Calendar = .current) -> Day? {
        completedAt.map { Day($0, calendar: calendar) }
    }
}

public struct ToDo: Schedulable {
    public static let kind = Kind.todo
    public let id: UUID
    public var values: [String: Value]

    public init(id: UUID, values: [String: Value]) {
        self.id = id
        self.values = values
    }

    public init(title: String, id: UUID = UUID()) {
        self.init(id: id, values: [Key.title: .string(title), Key.status: .string(Status.open.rawValue), Key.start: .string(Start.inbox.rawValue)])
    }

    public var projectID: UUID? {
        get { values.uuid(Key.project) }
        set { values[Key.project] = newValue.map { .string($0.uuidString) } ?? .null }
    }

    public var headingID: UUID? {
        get { values.uuid(Key.heading) }
        set { values[Key.heading] = newValue.map { .string($0.uuidString) } ?? .null }
    }

    public var repeatRule: RepeatRule? {
        get { values.optString(Key.repeatRule).flatMap(RepeatRule.init(encoded:)) }
        set { values[Key.repeatRule] = newValue.map { .string($0.encoded) } ?? .null }
    }

    /// Identifies all instances generated by the same repeating to-do.
    public var repeatSeries: UUID? {
        get { values.uuid(Key.repeatSeries) }
        set { values[Key.repeatSeries] = newValue.map { .string($0.uuidString) } ?? .null }
    }
}

public struct Project: Schedulable {
    public static let kind = Kind.project
    public let id: UUID
    public var values: [String: Value]

    public init(id: UUID, values: [String: Value]) {
        self.id = id
        self.values = values
    }

    public init(title: String, id: UUID = UUID()) {
        self.init(id: id, values: [Key.title: .string(title), Key.status: .string(Status.open.rawValue), Key.start: .string(Start.anytime.rawValue)])
    }
}

public struct Area: Entity {
    public static let kind = Kind.area
    public let id: UUID
    public var values: [String: Value]

    public init(id: UUID, values: [String: Value]) {
        self.id = id
        self.values = values
    }

    public init(title: String, id: UUID = UUID()) {
        self.init(id: id, values: [Key.title: .string(title)])
    }

    public var title: String {
        get { values.string(Key.title) }
        set { values[Key.title] = .string(newValue) }
    }

    public var tagIDs: [UUID] {
        get { values.uuids(Key.tags) }
        set { values[Key.tags] = .list(newValue.map(\.uuidString)) }
    }
}

public struct Heading: Entity {
    public static let kind = Kind.heading
    public let id: UUID
    public var values: [String: Value]

    public init(id: UUID, values: [String: Value]) {
        self.id = id
        self.values = values
    }

    public init(title: String, projectID: UUID, id: UUID = UUID()) {
        self.init(id: id, values: [Key.title: .string(title), Key.project: .string(projectID.uuidString)])
    }

    public var title: String {
        get { values.string(Key.title) }
        set { values[Key.title] = .string(newValue) }
    }

    public var projectID: UUID? {
        get { values.uuid(Key.project) }
        set { values[Key.project] = newValue.map { .string($0.uuidString) } ?? .null }
    }

    public var isArchived: Bool {
        get { values.bool(Key.archived) }
        set { values[Key.archived] = .bool(newValue) }
    }
}

public struct Tag: Entity {
    public static let kind = Kind.tag
    public let id: UUID
    public var values: [String: Value]

    public init(id: UUID, values: [String: Value]) {
        self.id = id
        self.values = values
    }

    public init(title: String, parentID: UUID? = nil, id: UUID = UUID()) {
        self.init(id: id, values: [Key.title: .string(title)])
        self.parentID = parentID
    }

    public var title: String {
        get { values.string(Key.title) }
        set { values[Key.title] = .string(newValue) }
    }

    public var parentID: UUID? {
        get { values.uuid(Key.parent) }
        set { values[Key.parent] = newValue.map { .string($0.uuidString) } ?? .null }
    }

    /// Single-character keyboard shortcut used to toggle the tag on Mac.
    public var shortcut: String? {
        get { values.optString(Key.shortcut).flatMap { $0.isEmpty ? nil : $0 } }
        set { values[Key.shortcut] = newValue.map { .string($0) } ?? .null }
    }
}

public struct ChecklistItem: Entity {
    public static let kind = Kind.checklist
    public let id: UUID
    public var values: [String: Value]

    public init(id: UUID, values: [String: Value]) {
        self.id = id
        self.values = values
    }

    public init(title: String, todoID: UUID, id: UUID = UUID()) {
        self.init(id: id, values: [Key.title: .string(title), Key.todo: .string(todoID.uuidString)])
    }

    public var title: String {
        get { values.string(Key.title) }
        set { values[Key.title] = .string(newValue) }
    }

    public var todoID: UUID? {
        get { values.uuid(Key.todo) }
        set { values[Key.todo] = newValue.map { .string($0.uuidString) } ?? .null }
    }

    public var isDone: Bool {
        get { values.bool(Key.done) }
        set { values[Key.done] = .bool(newValue) }
    }
}

// MARK: - Typed field access

public extension Dictionary where Key == String, Value == DabbleKit.Value {
    func string(_ key: String) -> String {
        optString(key) ?? ""
    }

    func optString(_ key: String) -> String? {
        if case .string(let value)? = self[key] { return value }
        return nil
    }

    func bool(_ key: String) -> Bool {
        if case .bool(let value)? = self[key] { return value }
        return false
    }

    func double(_ key: String) -> Double? {
        if case .number(let value)? = self[key] { return value }
        return nil
    }

    func day(_ key: String) -> Day? {
        optString(key).flatMap(Day.init)
    }

    func uuid(_ key: String) -> UUID? {
        optString(key).flatMap(UUID.init(uuidString:))
    }

    func uuids(_ key: String) -> [UUID] {
        if case .list(let values)? = self[key] { return values.compactMap(UUID.init(uuidString:)) }
        return []
    }
}
