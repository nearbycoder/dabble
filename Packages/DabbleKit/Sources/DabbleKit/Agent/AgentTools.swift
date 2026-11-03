import Foundation

/// A tool an AI agent can call. The same tools back the `dabble` CLI and its
/// MCP server, so anything you can do in the app, an agent can do too.
public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    /// The parameter a bare CLI argument fills, e.g. `dabble add "Buy milk"`.
    public let primary: String?
    /// True if the tool never changes data.
    public let readOnly: Bool
    let run: @MainActor @Sendable (AgentArguments, AgentToolbox) throws -> JSONValue
}

public struct AgentError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Typed access to a tool call's arguments.
public struct AgentArguments: Sendable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public func has(_ key: String) -> Bool { values[key] != nil }

    /// Present and explicitly null (or an empty string): "clear this".
    public func isCleared(_ key: String) -> Bool {
        switch values[key] {
        case .null?: true
        case .string(let s)? where s.trimmingCharacters(in: .whitespaces).isEmpty || s.lowercased() == "none" || s.lowercased() == "null": true
        default: false
        }
    }

    public func string(_ key: String) -> String? {
        switch values[key] {
        case .string(let value)?: value
        case .number(let value)?: value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value)?: String(value)
        default: nil
        }
    }

    public func requireString(_ key: String) throws -> String {
        guard let value = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AgentError("Missing required parameter “\(key)”.")
        }
        return value
    }

    /// Accepts a JSON array or a comma-separated string.
    public func strings(_ key: String) -> [String]? {
        switch values[key] {
        case .array(let items)?: items.compactMap { $0.stringValue ?? ($0 == .null ? nil : $0.encoded()) }
        case .string(let text)?: text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: nil
        }
    }

    /// Accepts a JSON array or a newline-separated string (for multi-line lists like checklist items).
    public func lines(_ key: String) -> [String]? {
        switch values[key] {
        case .array(let items)?: items.compactMap(\.stringValue)
        case .string(let text)?: text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: nil
        }
    }

    public func bool(_ key: String) -> Bool? {
        switch values[key] {
        case .bool(let value)?: value
        case .string(let text)?: ["true", "yes", "1", "on"].contains(text.lowercased()) ? true : (["false", "no", "0", "off"].contains(text.lowercased()) ? false : nil)
        case .number(let value)?: value != 0
        default: nil
        }
    }

    public func int(_ key: String) -> Int? {
        switch values[key] {
        case .number(let value)?: Int(value)
        case .string(let text)?: Int(text)
        default: nil
        }
    }
}

/// Runs agent tools against a store (and optionally a sync engine).
@MainActor
public final class AgentToolbox {
    public let store: DabbleStore
    public let sync: SyncEngine?
    public var today: Day

    public init(store: DabbleStore, sync: SyncEngine? = nil, today: Day = .today) {
        self.store = store
        self.sync = sync
        self.today = today
    }

    public nonisolated static let tools: [AgentTool] = AgentToolbox.makeTools()

    public nonisolated static func tool(named name: String) -> AgentTool? {
        let normalized = name.replacingOccurrences(of: "-", with: "_").lowercased()
        return tools.first { $0.name == normalized } ?? aliases[normalized].flatMap { alias in tools.first { $0.name == alias } }
    }

    /// Friendly CLI names.
    nonisolated static let aliases: [String: String] = [
        "add": "add_todo", "new": "add_todo", "list": "list_items", "ls": "list_items", "show": "get_item", "get": "get_item",
        "find": "search", "edit": "update_item", "update": "update_item", "status": "sync_status", "sync": "sync_now",
        "lists": "overview", "projects": "overview", "when": "schedule", "checklist": "edit_checklist", "delete": "delete_permanently",
    ]

    /// Calls a tool by name. Throws `AgentError` for bad input.
    public func call(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        guard let tool = Self.tool(named: name) else { throw AgentError("Unknown tool “\(name)”. Try overview, list_items, search, add_todo, update_item…") }
        today = .today
        return try store.batch { try tool.run(AgentArguments(arguments), self) }
    }

    // MARK: - Describing items

    func iso(_ date: Date?) -> JSONValue {
        date.map { .string($0.formatted(.iso8601)) } ?? .null
    }

    func ref(_ id: UUID?, _ title: String?) -> JSONValue {
        guard let id else { return .null }
        return ["id": .string(id.uuidString), "title": .string(title ?? "")]
    }

    func whenText<T: Schedulable>(_ item: T) -> String {
        if let todo = item as? ToDo, todo.start == .inbox, todo.projectID == nil, todo.areaID == nil { return "inbox" }
        if let date = item.startDate {
            if date <= today { return item.isEvening ? "this evening" : "today" }
            return date.description
        }
        return item.start == .someday ? "someday" : "anytime"
    }

    nonisolated static func timeText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    func tagNames(_ ids: [UUID]) -> JSONValue {
        .array(ids.compactMap { store.snapshot.tags[$0]?.title }.map { .string($0) })
    }

    func describe(_ todo: ToDo, detail: Bool = false) -> JSONValue {
        let snapshot = store.snapshot
        var object: [String: JSONValue] = [
            "id": .string(todo.id.uuidString),
            "type": "todo",
            "title": .string(todo.title),
            "status": .string(todo.status.rawValue),
            "when": .string(whenText(todo)),
        ]
        if !todo.tagIDs.isEmpty { object["tags"] = tagNames(todo.tagIDs) }
        if let deadline = todo.deadline { object["deadline"] = .string(deadline.description) }
        if let reminder = todo.reminder { object["reminder"] = .string(Self.timeText(reminder)) }
        if let projectID = todo.projectID { object["project"] = ref(projectID, snapshot.projects[projectID]?.title) }
        if let headingID = todo.headingID, let heading = snapshot.headings[headingID] { object["heading"] = ref(headingID, heading.title) }
        if let area = snapshot.area(of: todo) { object["area"] = ref(area.id, area.title) }
        if let rule = todo.repeatRule { object["repeat"] = .string(rule.summary) }
        if todo.completedAt != nil { object["completed_at"] = iso(todo.completedAt) }
        if todo.isTrashed { object["trashed"] = true }
        let checklist = snapshot.checklists[todo.id] ?? []
        if detail {
            object["notes"] = .string(todo.notes)
            object["checklist"] = .array(checklist.map { ["id": .string($0.id.uuidString), "title": .string($0.title), "done": .bool($0.isDone)] })
            object["created_at"] = iso(todo.createdAt)
            object["modified_at"] = iso(store.records[todo.id]?.modified.date)
        } else {
            if !todo.notes.isEmpty { object["has_notes"] = true }
            if !checklist.isEmpty { object["checklist"] = .string("\(checklist.filter(\.isDone).count)/\(checklist.count)") }
        }
        return .object(object)
    }

    func describe(_ project: Project, detail: Bool = false) -> JSONValue {
        let snapshot = store.snapshot
        let progress = snapshot.progress(of: project.id)
        var object: [String: JSONValue] = [
            "id": .string(project.id.uuidString),
            "type": "project",
            "title": .string(project.title),
            "status": .string(project.status.rawValue),
            "when": .string(whenText(project)),
            "progress": .string("\(progress.done)/\(progress.total)"),
        ]
        if let areaID = project.areaID { object["area"] = ref(areaID, snapshot.areas[areaID]?.title) }
        if !project.tagIDs.isEmpty { object["tags"] = tagNames(project.tagIDs) }
        if let deadline = project.deadline { object["deadline"] = .string(deadline.description) }
        if let reminder = project.reminder { object["reminder"] = .string(Self.timeText(reminder)) }
        if project.completedAt != nil { object["completed_at"] = iso(project.completedAt) }
        if project.isTrashed { object["trashed"] = true }
        if detail {
            object["notes"] = .string(project.notes)
            object["headings"] = .array(snapshot.headings(in: project.id).map {
                ["id": .string($0.id.uuidString), "title": .string($0.title), "archived": .bool($0.isArchived)]
            })
            let lists = store.lists(today: today)
            object["sections"] = describe(lists.project(project.id))
            object["logged_count"] = .number(Double(lists.loggedItems(in: .project(project.id)).count))
        }
        return .object(object)
    }

    func describe(_ area: Area, detail: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(area.id.uuidString), "type": "area", "title": .string(area.title)]
        if !area.tagIDs.isEmpty { object["tags"] = tagNames(area.tagIDs) }
        if area.isTrashed { object["trashed"] = true }
        if detail {
            object["sections"] = describe(store.lists(today: today).area(area.id))
        }
        return .object(object)
    }

    func describe(_ tag: Tag) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(tag.id.uuidString), "type": "tag", "title": .string(tag.title)]
        if let parentID = tag.parentID { object["parent"] = ref(parentID, store.snapshot.tags[parentID]?.title) }
        if let shortcut = tag.shortcut { object["shortcut"] = .string(shortcut) }
        return .object(object)
    }

    func describe(_ heading: Heading) -> JSONValue {
        [
            "id": .string(heading.id.uuidString), "type": "heading", "title": .string(heading.title),
            "project": ref(heading.projectID, heading.projectID.flatMap { store.snapshot.projects[$0]?.title }),
            "archived": .bool(heading.isArchived),
        ]
    }

    func describe(_ item: Item, detail: Bool = false) -> JSONValue {
        switch item {
        case .todo(let x): describe(x, detail: detail)
        case .project(let x): describe(x, detail: detail)
        case .area(let x): describe(x, detail: detail)
        case .tag(let x): describe(x)
        case .heading(let x): describe(x)
        }
    }

    func sectionTitle(_ header: GroupHeader) -> JSONValue {
        switch header {
        case .none: .null
        case .evening: "This Evening"
        case .area(let area): .string(area.title)
        case .project(let project): .string(project.title)
        case .heading(let heading): .string(heading.title)
        case .day(let day): .string("\(day.description) (\(day.date().formatted(.dateTime.weekday(.wide))))")
        case .month(let year, let month): .string(String(format: "%04d-%02d", year, month))
        case .later: "Later (someday)"
        case .completed: "Completed"
        }
    }

    func describe(_ groups: [ItemGroup], limit: Int? = nil) -> JSONValue {
        var remaining = limit ?? .max
        var result: [JSONValue] = []
        for group in groups where !group.items.isEmpty || { if case .heading = group.header { true } else { false } }() {
            guard remaining > 0 else { break }
            let items = Array(group.items.prefix(remaining))
            remaining -= items.count
            var section: [String: JSONValue] = ["items": .array(items.map { describe($0) })]
            let title = sectionTitle(group.header)
            if title != .null { section["section"] = title }
            if case .heading(let heading) = group.header { section["heading_id"] = .string(heading.id.uuidString) }
            result.append(.object(section))
        }
        return .array(result)
    }

    // MARK: - Resolving arguments

    func parseUUID(_ text: String) -> UUID? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespaces))
    }

    /// A list by built-in name, or a project, area or tag by id or title.
    func resolveList(_ text: String) throws -> ListID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let list = store.resolveList(trimmed) { return list }
        if let id = parseUUID(trimmed), store.tag(id) != nil { return .tag(id) }
        let lowered = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let tag = store.snapshot.tags.values.first(where: { $0.title.lowercased() == lowered }) { return .tag(tag.id) }
        if lowered == "this evening" || lowered == "evening" { return .today }
        throw AgentError("No list, project, area or tag called “\(trimmed)”. Use overview to see what exists.")
    }

    /// Finds an item by full id, or by a unique prefix of at least 6 characters.
    func record(_ text: String) throws -> Record {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = parseUUID(trimmed), let record = store.records[id], !record.values.bool(Key.purged) { return record }
        let prefix = trimmed.uppercased()
        if prefix.count >= 6, prefix.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let matches = store.records.values.filter { $0.id.uuidString.hasPrefix(prefix) && !$0.values.bool(Key.purged) }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw AgentError("“\(text)” matches several items; use more of the id.") }
        }
        throw AgentError("No item with id “\(text)”. Ids come from list_items, search or overview.")
    }

    func ids(_ arguments: AgentArguments) throws -> [UUID] {
        let raw = arguments.strings("ids") ?? arguments.string("id").map { [$0] } ?? []
        guard !raw.isEmpty else { throw AgentError("Missing “ids” (an array of item ids).") }
        return try raw.map { try record($0).id }
    }

    func parseWhen(_ text: String) throws -> When {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered == "this evening" { return .evening }
        guard let when = When.parse(text, today: today) else {
            throw AgentError("Couldn't understand when “\(text)”. Use today, this evening, tomorrow, anytime, someday, inbox, a weekday, “in 3 days” or YYYY-MM-DD.")
        }
        return when
    }

    func parseDay(_ text: String) throws -> Day {
        switch try parseWhen(text) {
        case .date(let day): return day
        case .today, .evening: return today
        default: throw AgentError("A deadline needs a date, like 2026-12-01, “fri” or “in 2 weeks”.")
        }
    }

    /// "9:30", "09:30", "9am", "5:15 pm", "17:00" → minutes after midnight.
    nonisolated static func parseTime(_ text: String) -> Int? {
        var t = text.lowercased().replacingOccurrences(of: " ", with: "")
        var offset = 0
        if t.hasSuffix("am") { t.removeLast(2) } else if t.hasSuffix("pm") { t.removeLast(2); offset = 12 }
        let parts = t.split(separator: ":").map(String.init)
        guard let hour = Int(parts.first ?? ""), parts.count <= 2 else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        var h = hour
        if offset == 12 && h < 12 { h += 12 }
        if offset == 0 && text.lowercased().contains("am") && h == 12 { h = 0 }
        guard (0..<24).contains(h), (0..<60).contains(minute) else { return nil }
        return h * 60 + minute
    }

    /// "daily", "weekly", "every 2 weeks", "every monday and thursday", "monthly after completion", or an object.
    func parseRepeat(_ value: JSONValue) throws -> RepeatRule {
        if let object = value.objectValue {
            let args = AgentArguments(object)
            let unit = RepeatRule.Unit(rawValue: (args.string("unit") ?? "week").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "s"))) ?? .week
            let mode: RepeatRule.Mode = (args.string("mode") ?? "").lowercased().contains("after") ? .afterCompletion : .schedule
            let weekdays = (args.strings("weekdays") ?? []).compactMap(Self.weekday)
            let until = try args.string("until").map(parseDay)
            return RepeatRule(unit: unit, interval: args.int("every") ?? args.int("interval") ?? 1, mode: mode, weekdays: weekdays, until: until)
        }
        guard let text = value.stringValue?.lowercased() else { throw AgentError("“repeat” should be text like “weekly” or an object.") }
        let mode: RepeatRule.Mode = text.contains("after") ? .afterCompletion : .schedule
        let words = text.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        let weekdays = words.compactMap(Self.weekday)
        let interval = words.compactMap { Int($0) }.first ?? (words.contains("other") ? 2 : 1)
        let unit: RepeatRule.Unit
        if text.contains("daily") || words.contains(where: { $0.hasPrefix("day") }) { unit = .day }
        else if text.contains("month") { unit = .month }
        else if text.contains("year") || text.contains("annual") { unit = .year }
        else if text.contains("week") || !weekdays.isEmpty { unit = .week }
        else { throw AgentError("Couldn't understand repeat “\(text)”. Try daily, weekly, every 2 weeks, every monday, monthly, yearly, or add “after completion”.") }
        return RepeatRule(unit: unit, interval: interval, mode: mode, weekdays: weekdays)
    }

    nonisolated static func weekday(_ text: String) -> Int? {
        guard text.count >= 2 else { return nil }
        return When.weekdayIndex(text).map { $0 + 1 }
    }

    /// Tag ids for names (or ids), creating tags that don't exist yet.
    func tagIDs(_ names: [String]) -> [UUID] {
        names.map { name in
            if let id = parseUUID(name), store.tag(id) != nil { return id }
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            return store.snapshot.tags.values.first { $0.title.caseInsensitiveCompare(clean) == .orderedSame }?.id ?? store.addTag(clean).id
        }
    }

    func headingID(_ text: String, in projectID: UUID) throws -> UUID {
        if let id = parseUUID(text), store.heading(id)?.projectID == projectID { return id }
        if let heading = store.snapshot.headings(in: projectID).first(where: { $0.title.caseInsensitiveCompare(text) == .orderedSame }) {
            return heading.id
        }
        return store.addHeading(text, in: projectID).id
    }

    func destination(_ text: String, heading: String?) throws -> Destination {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "inbox": return .inbox
        case "none", "no project", "": return .none
        default: break
        }
        switch try resolveList(text) {
        case .project(let id): return .project(id, heading: try heading.map { try headingID($0, in: id) })
        case .area(let id): return .area(id)
        case .inbox: return .inbox
        default: throw AgentError("“\(text)” isn't a project or area. To schedule, use “when” instead.")
        }
    }

    func requireGroup() throws -> SyncEngine {
        guard let sync else { throw AgentError("Sync isn't available here.") }
        return sync
    }
}
