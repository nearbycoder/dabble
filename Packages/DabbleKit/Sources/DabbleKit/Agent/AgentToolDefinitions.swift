import Foundation

// The catalogue of agent tools. Descriptions are written for a language model:
// they explain Dabble's (Things-style) concepts so an agent uses them correctly.

private enum S {
    static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    static func nullableString(_ description: String) -> JSONValue { ["type": ["string", "null"], "description": .string(description)] }
    static func strings(_ description: String) -> JSONValue { ["type": "array", "items": ["type": "string"], "description": .string(description)] }
    static func bool(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
    static func int(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }), "additionalProperties": false]
    }

    static let when = string("When to do it: “today”, “this evening”, “tomorrow”, a weekday (“fri”), “next week”, “in 3 days”, a date (YYYY-MM-DD), “anytime” (no date), “someday” (parked) or “inbox”. This is the start date, not a due date.")
    static let deadline = nullableString("Due date (YYYY-MM-DD or natural language like “fri”). Shows a countdown and puts the item in Today when due. null clears it.")
    static let reminder = nullableString("Notification time on the item's “when” day, e.g. “09:30” or “5pm”. Sets when to today if it has no date. null clears it.")
    static let tags = strings("Tag names (created if they don't exist) or ids.")
    static let repeatRule = ["description": "How it repeats: “daily”, “weekly”, “every 2 weeks”, “every monday and thursday”, “monthly”, “yearly”, optionally “… after completion”; or {unit, every, weekdays, mode, until}. null stops repeating. Repeating needs a when date; today is used if missing.",
                             "anyOf": [["type": "string"], ["type": "object"], ["type": "null"]]] as JSONValue
    static let ids = strings("Item ids (from list_items, search, overview or get_item).")
}

extension AgentToolbox {
    nonisolated static func makeTools() -> [AgentTool] {
        [
            // MARK: Reading

            AgentTool(
                name: "overview",
                description: "The sidebar: counts for Inbox and Today, all areas with their open projects, projects without an area, and tags. Start here to learn ids and names.",
                inputSchema: S.object([:]), primary: nil, readOnly: true
            ) { _, box in
                let snapshot = box.store.snapshot
                let lists = box.store.lists(today: box.today)
                @MainActor func project(_ p: Project) -> JSONValue {
                    ["id": .string(p.id.uuidString), "title": .string(p.title), "open_todos": .number(Double(lists.openCount(project: p.id))), "when": .string(box.whenText(p))]
                }
                var result: [String: JSONValue] = [
                    "today": .string(box.today.description),
                    "counts": ["inbox": .number(Double(lists.inboxCount)), "today": .number(Double(lists.todayCount)), "due_or_overdue": .number(Double(lists.todayDueCount))],
                    "lists": ["inbox", "today", "upcoming", "anytime", "someday", "logbook", "trash"],
                    "projects_without_area": .array(snapshot.openProjects(in: nil).map(project)),
                    "areas": .array(snapshot.areaList.map { area in
                        ["id": .string(area.id.uuidString), "title": .string(area.title), "tags": box.tagNames(area.tagIDs), "projects": .array(snapshot.openProjects(in: area.id).map(project))]
                    }),
                    "tags": .array(snapshot.tagList.map { box.describe($0) }),
                ]
                if let sync = box.sync { result["sync"] = box.syncStatus(sync) }
                return .object(result)
            },

            AgentTool(
                name: "list_items",
                description: "Shows a list the way the app does. Built-in lists: inbox (unsorted), today (incl. a This Evening section and anything due), upcoming (scheduled, by day), anytime (actionable now, by area/project), someday (parked), logbook (completed), trash. Or pass a project, area or tag by name or id.",
                inputSchema: S.object([
                    "list": S.string("inbox, today, upcoming, anytime, someday, logbook, trash, or a project/area/tag name or id."),
                    "tag": S.string("Only items with this tag (or a child tag). Tags are inherited from projects and areas."),
                    "include_logged": S.bool("For a project or area, also list its completed/canceled to-dos."),
                    "limit": S.int("Maximum number of items (default 200)."),
                ], required: ["list"]),
                primary: "list", readOnly: true
            ) { args, box in
                let list = try box.resolveList(try args.requireString("list"))
                let lists = box.store.lists(today: box.today)
                var groups = lists.items(for: list)
                if let tag = args.string("tag") {
                    guard case .tag(let id) = try box.resolveList(tag) else { throw AgentError("No tag called “\(tag)”.") }
                    groups = lists.filter(groups, tag: id)
                }
                var result: [String: JSONValue] = [
                    "list": .string(list.title(in: box.store)),
                    "sections": box.describe(groups, limit: args.int("limit") ?? 200),
                ]
                switch list {
                case .project(let id): result["project"] = box.describe(box.store.project(id)!)
                case .area(let id): result["area"] = box.describe(box.store.area(id)!)
                default: break
                }
                if args.bool("include_logged") == true {
                    result["logged"] = .array(lists.loggedItems(in: list).map { box.describe($0) })
                }
                return .object(result)
            },

            AgentTool(
                name: "search",
                description: "Finds to-dos, projects, areas and tags whose title, notes or checklist contain all the words in the query.",
                inputSchema: S.object([
                    "query": S.string("Words to find."),
                    "include_completed": S.bool("Include completed and canceled items (default true)."),
                    "limit": S.int("Maximum results (default 50)."),
                ], required: ["query"]),
                primary: "query", readOnly: true
            ) { args, box in
                let results = box.store.lists(today: box.today).search(try args.requireString("query"), includeCompleted: args.bool("include_completed") ?? true)
                return ["results": .array(results.prefix(args.int("limit") ?? 50).map { box.describe($0) })]
            },

            AgentTool(
                name: "get_item",
                description: "Full details of one item: a to-do's notes and checklist; a project's notes, headings and to-dos by section; an area's projects and to-dos; or a tag/heading.",
                inputSchema: S.object(["id": S.string("Item id.")], required: ["id"]),
                primary: "id", readOnly: true
            ) { args, box in
                let record = try box.record(try args.requireString("id"))
                switch record.kind {
                case .todo: return box.describe(ToDo(record: record), detail: true)
                case .project: return box.describe(Project(record: record), detail: true)
                case .area: return box.describe(Area(record: record), detail: true)
                case .tag: return box.describe(Tag(record: record))
                case .heading: return box.describe(Heading(record: record))
                case .checklist:
                    let item = ChecklistItem(record: record)
                    return ["id": .string(item.id.uuidString), "type": "checklist_item", "title": .string(item.title), "done": .bool(item.isDone), "todo_id": .string(item.todoID?.uuidString ?? "")]
                }
            },

            // MARK: Creating

            AgentTool(
                name: "add_todo",
                description: "Adds a to-do. Without a list it goes to the Inbox. Give a project, area or built-in list (today, anytime, someday, upcoming) in “list”; “when” and “deadline” are separate: when = the day you plan to do it, deadline = when it's due.",
                inputSchema: S.object([
                    "title": S.string("The to-do."),
                    "notes": S.string("Notes (plain text, links allowed)."),
                    "list": S.string("Where it goes: inbox (default), today, anytime, someday, upcoming, or a project/area name or id."),
                    "heading": S.string("Heading within the project (name or id; created if missing)."),
                    "when": S.when,
                    "deadline": S.deadline,
                    "reminder": S.reminder,
                    "tags": S.tags,
                    "checklist": S.strings("Checklist items."),
                    "repeat": S.repeatRule,
                ], required: ["title"]),
                primary: "title", readOnly: false
            ) { args, box in
                let title = try args.requireString("title")
                let list = try args.string("list").map { try box.resolveList($0) } ?? .inbox
                var heading: UUID?
                if let name = args.string("heading") {
                    guard case .project(let projectID) = list else { throw AgentError("“heading” needs a project in “list”.") }
                    heading = try box.headingID(name, in: projectID)
                }
                let when = try args.string("when").map { try box.parseWhen($0) }
                let todo = box.store.addToDo(title, notes: args.string("notes") ?? "", in: list, heading: heading, when: when, today: box.today)
                try box.applyCommon(args, to: todo.id)
                for line in args.lines("checklist") ?? [] { box.store.addChecklistItem(line, to: todo.id) }
                return box.describe(box.store.todo(todo.id)!, detail: true)
            },

            AgentTool(
                name: "add_project",
                description: "Adds a project (a goal with several to-dos), optionally in an area, with headings and to-dos.",
                inputSchema: S.object([
                    "title": S.string("Project name."),
                    "notes": S.string("Notes."),
                    "area": S.string("Area name or id."),
                    "when": S.when,
                    "deadline": S.deadline,
                    "tags": S.tags,
                    "headings": S.strings("Headings to create, in order."),
                    "todos": S.strings("To-dos to add (not under a heading)."),
                ], required: ["title"]),
                primary: "title", readOnly: false
            ) { args, box in
                var areaID: UUID?
                if let area = args.string("area") {
                    guard case .area(let id) = try box.resolveList(area) else { throw AgentError("No area called “\(area)”.") }
                    areaID = id
                }
                let project = box.store.addProject(try args.requireString("title"), area: areaID, when: try args.string("when").map { try box.parseWhen($0) })
                if let notes = args.string("notes") { box.store.update(Project.self, project.id) { $0.notes = notes } }
                try box.applyCommon(args, to: project.id)
                for heading in args.lines("headings") ?? [] { box.store.addHeading(heading, in: project.id) }
                for title in args.lines("todos") ?? [] { box.store.addToDo(title, in: .project(project.id), today: box.today) }
                return box.describe(box.store.project(project.id)!, detail: true)
            },

            AgentTool(
                name: "add_area",
                description: "Adds an area: an ongoing part of life (Work, Home, Health) that holds projects and to-dos.",
                inputSchema: S.object(["title": S.string("Area name."), "tags": S.tags], required: ["title"]),
                primary: "title", readOnly: false
            ) { args, box in
                let area = box.store.addArea(try args.requireString("title"))
                if let tags = args.strings("tags") { box.store.setTags(area.id, box.tagIDs(tags)) }
                return box.describe(box.store.area(area.id)!)
            },

            AgentTool(
                name: "add_heading",
                description: "Adds a heading (section) to a project.",
                inputSchema: S.object(["project": S.string("Project name or id."), "title": S.string("Heading.")], required: ["project", "title"]),
                primary: "title", readOnly: false
            ) { args, box in
                guard case .project(let id) = try box.resolveList(try args.requireString("project")) else { throw AgentError("That isn't a project.") }
                return box.describe(box.store.addHeading(try args.requireString("title"), in: id))
            },

            AgentTool(
                name: "add_tag",
                description: "Adds a tag, optionally nested under a parent tag.",
                inputSchema: S.object(["title": S.string("Tag name."), "parent": S.string("Parent tag name or id.")], required: ["title"]),
                primary: "title", readOnly: false
            ) { args, box in
                let parent = args.string("parent").map { box.tagIDs([$0])[0] }
                return box.describe(box.store.addTag(try args.requireString("title"), parent: parent))
            },

            // MARK: Changing

            AgentTool(
                name: "update_item",
                description: "Changes a to-do, project, area, heading, tag or checklist item. Only the fields you pass change; null clears deadline/reminder/repeat. For to-dos and projects: title, notes, append_notes, when, deadline, reminder, tags/add_tags/remove_tags, move_to (+heading), repeat (to-dos). Areas: title, tags. Headings: title, archived. Tags: title, parent, shortcut. Checklist items: title, done.",
                inputSchema: S.object([
                    "id": S.string("Item id."),
                    "title": S.string("New title."),
                    "notes": S.string("Replace notes."),
                    "append_notes": S.string("Add a line to the end of the notes."),
                    "when": S.when,
                    "deadline": S.deadline,
                    "reminder": S.reminder,
                    "tags": S.tags,
                    "add_tags": S.tags,
                    "remove_tags": S.tags,
                    "move_to": S.string("Project or area (name or id), “inbox”, or “none” to take it out of its project/area."),
                    "heading": S.string("Heading within the destination project (name or id)."),
                    "repeat": S.repeatRule,
                    "archived": S.bool("Headings: archive (hide) it."),
                    "parent": S.nullableString("Tags: parent tag (name or id), or null for top level."),
                    "shortcut": S.nullableString("Tags: single-character keyboard shortcut for the Mac app."),
                    "done": S.bool("Checklist items: checked or not."),
                ], required: ["id"]),
                primary: "id", readOnly: false
            ) { args, box in
                try box.update(args)
            },

            AgentTool(
                name: "set_status",
                description: "Completes, cancels or reopens to-dos or projects. Completing a project completes its remaining to-dos; completing a repeating to-do schedules the next one.",
                inputSchema: S.object(["ids": S.ids, "status": ["type": "string", "enum": ["completed", "canceled", "open"], "description": "New status (default completed)."]], required: ["ids"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let status = Status(rawValue: (args.string("status") ?? "completed").lowercased().replacingOccurrences(of: "cancelled", with: "canceled")) ?? .completed
                let ids = try box.ids(args)
                box.store.setStatus(ids, status, today: box.today)
                return ["updated": .array(ids.compactMap { id in box.store.todo(id).map { box.describe($0) } ?? box.store.project(id).map { box.describe($0) } })]
            },

            AgentTool(
                name: "schedule",
                description: "Sets “when” for several to-dos or projects at once (today, this evening, tomorrow, a date, anytime, someday, inbox).",
                inputSchema: S.object(["ids": S.ids, "when": S.when], required: ["ids", "when"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let ids = try box.ids(args)
                box.store.schedule(ids, try box.parseWhen(try args.requireString("when")), today: box.today)
                return ["updated": .array(ids.compactMap { id in box.store.todo(id).map { box.describe($0) } ?? box.store.project(id).map { box.describe($0) } })]
            },

            AgentTool(
                name: "move",
                description: "Moves to-dos into a project (optionally under a heading), an area, the inbox, or out of any project (“none”). Moves projects between areas.",
                inputSchema: S.object(["ids": S.ids, "to": S.string("Project or area name/id, “inbox” or “none”."), "heading": S.string("Heading in the project (name or id).")], required: ["ids", "to"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let ids = try box.ids(args)
                box.store.move(ids, to: try box.destination(try args.requireString("to"), heading: args.string("heading")))
                return ["updated": .array(ids.compactMap { id in box.store.todo(id).map { box.describe($0) } ?? box.store.project(id).map { box.describe($0) } })]
            },

            AgentTool(
                name: "edit_checklist",
                description: "Edits a to-do's checklist: add items, check/uncheck, rename or remove them.",
                inputSchema: S.object([
                    "todo": S.string("To-do id."),
                    "add": S.strings("New checklist items, appended."),
                    "check": S.strings("Checklist item ids to check."),
                    "uncheck": S.strings("Checklist item ids to uncheck."),
                    "remove": S.strings("Checklist item ids to delete."),
                    "rename": ["type": "array", "items": ["type": "object", "properties": ["id": ["type": "string"], "title": ["type": "string"]]], "description": "[{id, title}] pairs."],
                ], required: ["todo"]),
                primary: "todo", readOnly: false
            ) { args, box in
                let todo = try box.record(try args.requireString("todo"))
                guard todo.kind == .todo else { throw AgentError("That id isn't a to-do.") }
                for title in args.lines("add") ?? [] { box.store.addChecklistItem(title, to: todo.id) }
                for (key, done) in [("check", true), ("uncheck", false)] {
                    for id in args.strings(key) ?? [] { box.store.update(ChecklistItem.self, try box.record(id).id) { $0.isDone = done } }
                }
                for id in args.strings("remove") ?? [] { box.store.delete(try box.record(id).id) }
                for pair in args.values["rename"]?.arrayValue ?? [] {
                    guard let id = pair["id"]?.stringValue, let title = pair["title"]?.stringValue else { continue }
                    box.store.update(ChecklistItem.self, try box.record(id).id) { $0.title = title }
                }
                return box.describe(box.store.todo(todo.id)!, detail: true)
            },

            AgentTool(
                name: "reorder",
                description: "Puts items in the given order within their list (only out-of-place items move). Set today=true to reorder the Today list.",
                inputSchema: S.object(["ids": S.strings("Item ids in the desired order."), "today": S.bool("Reorder within Today (default false).")], required: ["ids"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let ids = try box.ids(args)
                box.store.reorder(ids, key: args.bool("today") == true ? Key.todayIndex : Key.index)
                return ["ok": true]
            },

            AgentTool(
                name: "duplicate",
                description: "Duplicates to-dos (with their checklists).",
                inputSchema: S.object(["ids": S.ids], required: ["ids"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let copies = try box.ids(args).compactMap { box.duplicateToDo($0) }
                return ["created": .array(copies.compactMap { box.store.todo($0).map { box.describe($0, detail: true) } })]
            },

            AgentTool(
                name: "convert_to_project",
                description: "Turns a to-do into a project; its checklist items become to-dos.",
                inputSchema: S.object(["id": S.string("To-do id.")], required: ["id"]),
                primary: "id", readOnly: false
            ) { args, box in
                guard let project = box.store.convertToProject(try box.record(try args.requireString("id")).id) else { throw AgentError("That id isn't a to-do.") }
                return box.describe(project, detail: true)
            },

            // MARK: Deleting

            AgentTool(
                name: "trash",
                description: "Moves items to the Trash (recoverable with restore). Projects and areas take their contents with them.",
                inputSchema: S.object(["ids": S.ids], required: ["ids"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let ids = try box.ids(args)
                box.store.trash(ids)
                return ["trashed": .number(Double(ids.count))]
            },

            AgentTool(
                name: "restore",
                description: "Takes items back out of the Trash.",
                inputSchema: S.object(["ids": S.ids], required: ["ids"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let ids = try box.ids(args)
                box.store.restore(ids)
                return ["restored": .number(Double(ids.count))]
            },

            AgentTool(
                name: "delete_permanently",
                description: "Permanently deletes items on every synced device. Can't be undone. Use for tags, headings and checklist items, or items already in the Trash; prefer trash for to-dos and projects. Ask the user first.",
                inputSchema: S.object(["ids": S.ids], required: ["ids"]),
                primary: "ids", readOnly: false
            ) { args, box in
                let ids = try box.ids(args)
                for id in ids {
                    if let kind = box.store.records[id]?.kind, kind == .project || kind == .area {
                        // Take contents along, like emptying the Trash would.
                        box.store.trash([id])
                        let doomed = box.store.records.values.filter { $0.values.bool(Key.trashed) && ($0.values.uuid(Key.project) == id || $0.values.uuid(Key.area) == id) }
                        for record in doomed { box.store.delete(record.id) }
                    }
                    box.store.delete(id)
                }
                return ["deleted": .number(Double(ids.count))]
            },

            AgentTool(
                name: "empty_trash",
                description: "Permanently deletes everything in the Trash on every synced device. Can't be undone. Ask the user first.",
                inputSchema: S.object(["confirm": S.bool("Must be true.")], required: ["confirm"]),
                primary: nil, readOnly: false
            ) { args, box in
                guard args.bool("confirm") == true else { throw AgentError("Pass confirm: true to empty the Trash.") }
                let count = box.store.lists(today: box.today).trash().flatMap(\.items).count
                box.store.emptyTrash()
                return ["deleted": .number(Double(count))]
            },

            // MARK: Other

            AgentTool(
                name: "open_url",
                description: "Runs a dabble:/// URL (the app's URL scheme: add, add-project, show, search) and returns what it did.",
                inputSchema: S.object(["url": S.string("A dabble:/// URL.")], required: ["url"]),
                primary: "url", readOnly: false
            ) { args, box in
                guard let url = URL(string: try args.requireString("url")) else { throw AgentError("That isn't a URL.") }
                switch try box.store.perform(url, today: box.today) {
                case .added(let id), .showItem(let id):
                    if let todo = box.store.todo(id) { return box.describe(todo, detail: true) }
                    if let project = box.store.project(id) { return box.describe(project, detail: true) }
                    return ["id": .string(id.uuidString)]
                case .show(let list): return ["list": .string(list.title(in: box.store))]
                case .search(let query): return ["results": .array(box.store.lists(today: box.today).search(query).prefix(50).map { box.describe($0) })]
                }
            },

            AgentTool(
                name: "sync_status",
                description: "Whether this agent's copy is connected to the user's devices or sync server, and when it last synced.",
                inputSchema: S.object([:]), primary: nil, readOnly: true
            ) { _, box in
                box.syncStatus(try box.requireGroup())
            },

            AgentTool(
                name: "sync_now",
                description: "Reconnects to the user's devices and sync server right away.",
                inputSchema: S.object([:]), primary: nil, readOnly: true
            ) { _, box in
                let sync = try box.requireGroup()
                sync.syncNow()
                return box.syncStatus(sync)
            },
        ]
    }
}

extension AgentToolbox {
    func syncStatus(_ sync: SyncEngine) -> JSONValue {
        var server: JSONValue = .null
        if let url = sync.serverURL {
            let status: String
            switch sync.serverStatus {
            case .off: status = "off"
            case .connecting: status = "connecting"
            case .connected: status = "connected"
            case .error(let message): status = "error: \(message)"
            }
            server = ["url": .string(url.absoluteString), "status": .string(status), "last_sync": iso(sync.serverLastSync)]
        }
        return [
            "joined": .bool(sync.hasGroup),
            "device_name": .string(sync.deviceName),
            "devices": .array(sync.peers.map { ["name": .string($0.name), "platform": .string($0.platform), "connected": .bool($0.isConnected), "last_sync": iso($0.lastSync)] }),
            "server": server,
            "last_sync": iso(sync.lastSync ?? sync.serverLastSync),
        ]
    }

    /// Fields shared by add_todo, add_project and update_item.
    func applyCommon(_ args: AgentArguments, to id: UUID) throws {
        if args.isCleared("deadline") {
            store.setDeadline([id], nil)
        } else if let deadline = args.string("deadline") {
            store.setDeadline([id], try parseDay(deadline))
        }
        if args.isCleared("reminder") {
            store.setReminder(id, minutes: nil, today: today)
        } else if let reminder = args.string("reminder") {
            guard let minutes = Self.parseTime(reminder) else { throw AgentError("Couldn't understand reminder time “\(reminder)”. Use 09:30 or 5pm.") }
            store.setReminder(id, minutes: minutes, today: today)
        }
        if let tags = args.strings("tags") { store.setTags(id, tagIDs(tags)) }
        if let add = args.strings("add_tags") {
            let current = store.todo(id)?.tagIDs ?? store.project(id)?.tagIDs ?? store.area(id)?.tagIDs ?? []
            store.setTags(id, current + tagIDs(add).filter { !current.contains($0) })
        }
        if let remove = args.strings("remove_tags") {
            let doomed = Set(tagIDs(remove))
            let current = store.todo(id)?.tagIDs ?? store.project(id)?.tagIDs ?? store.area(id)?.tagIDs ?? []
            store.setTags(id, current.filter { !doomed.contains($0) })
        }
        if args.has("repeat") {
            guard store.todo(id) != nil else { throw AgentError("Only to-dos can repeat.") }
            store.setRepeat(id, args.isCleared("repeat") ? nil : try parseRepeat(args.values["repeat"]!), today: today)
        }
    }

    func update(_ args: AgentArguments) throws -> JSONValue {
        let record = try record(try args.requireString("id"))
        let id = record.id
        switch record.kind {
        case .todo, .project:
            if let title = args.string("title") {
                record.kind == .todo ? store.update(ToDo.self, id) { $0.title = title } : store.update(Project.self, id) { $0.title = title }
            }
            if let notes = args.string("notes") {
                record.kind == .todo ? store.update(ToDo.self, id) { $0.notes = notes } : store.update(Project.self, id) { $0.notes = notes }
            }
            if let extra = args.string("append_notes") {
                let append: (String) -> String = { $0.isEmpty ? extra : $0 + "\n" + extra }
                record.kind == .todo ? store.update(ToDo.self, id) { $0.notes = append($0.notes) } : store.update(Project.self, id) { $0.notes = append($0.notes) }
            }
            if let when = args.string("when") { store.schedule([id], try parseWhen(when), today: today) }
            if let target = args.string("move_to") {
                store.move([id], to: try destination(target, heading: args.string("heading")))
            } else if let heading = args.string("heading"), let projectID = store.todo(id)?.projectID {
                store.move([id], to: .project(projectID, heading: try headingID(heading, in: projectID)))
            }
            try applyCommon(args, to: id)
            return store.todo(id).map { describe($0, detail: true) } ?? describe(store.project(id)!, detail: true)
        case .area:
            if let title = args.string("title") { store.update(Area.self, id) { $0.title = title } }
            if let tags = args.strings("tags") { store.setTags(id, tagIDs(tags)) }
            return describe(store.area(id)!)
        case .heading:
            if let title = args.string("title") { store.update(Heading.self, id) { $0.title = title } }
            if let archived = args.bool("archived") { store.update(Heading.self, id) { $0.isArchived = archived } }
            return describe(store.heading(id)!)
        case .tag:
            if let title = args.string("title") { store.update(Tag.self, id) { $0.title = title } }
            if args.isCleared("parent") {
                store.update(Tag.self, id) { $0.parentID = nil }
            } else if let parent = args.string("parent") {
                let parentID = tagIDs([parent])[0]
                guard !store.snapshot.tagFamily(id).contains(parentID) else { throw AgentError("A tag can't be nested inside itself.") }
                store.update(Tag.self, id) { $0.parentID = parentID }
            }
            if args.has("shortcut") {
                let shortcut = args.isCleared("shortcut") ? nil : args.string("shortcut").map { String($0.prefix(1)).lowercased() }
                store.update(Tag.self, id) { $0.shortcut = shortcut }
            }
            return describe(store.tag(id)!)
        case .checklist:
            if let title = args.string("title") { store.update(ChecklistItem.self, id) { $0.title = title } }
            if let done = args.bool("done") { store.update(ChecklistItem.self, id) { $0.isDone = done } }
            let item = ChecklistItem(record: store.records[id]!)
            return ["id": .string(id.uuidString), "type": "checklist_item", "title": .string(item.title), "done": .bool(item.isDone)]
        }
    }

    func duplicateToDo(_ id: UUID) -> UUID? {
        guard let todo = store.todo(id) else { return nil }
        var values = todo.values
        values[Key.createdAt] = nil
        values[Key.repeatSeries] = nil
        let copy = ToDo(id: UUID(), values: values)
        store.save(copy)
        for item in store.snapshot.checklists[id] ?? [] {
            var newItem = ChecklistItem(title: item.title, todoID: copy.id)
            newItem.isDone = item.isDone
            newItem.index = item.index
            store.save(newItem)
        }
        return copy.id
    }
}

extension ListID {
    /// Plain title, as an agent would read it.
    @MainActor
    func title(in store: DabbleStore) -> String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .logbook: "Logbook"
        case .trash: "Trash"
        case .project(let id): store.project(id)?.title ?? "Project"
        case .area(let id): store.area(id)?.title ?? "Area"
        case .tag(let id): store.tag(id)?.title ?? "Tag"
        }
    }
}
