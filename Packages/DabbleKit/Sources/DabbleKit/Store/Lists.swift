import Foundation

/// The lists a user can navigate to.
public enum ListID: Hashable, Codable, Sendable {
    case inbox
    case today
    case upcoming
    case anytime
    case someday
    case logbook
    case trash
    case project(UUID)
    case area(UUID)
    case tag(UUID)
}

/// A section header within a list.
public enum GroupHeader: Hashable, Sendable {
    case none
    case evening
    case area(Area)
    case project(Project)
    case heading(Heading)
    case day(Day)
    case month(year: Int, month: Int)
    /// Things' "Later" section: someday to-dos inside a project or area.
    case later
    case completed
}

public struct ItemGroup: Identifiable, Hashable, Sendable {
    public var header: GroupHeader
    public var items: [Item]

    public var id: String {
        switch header {
        case .none: "none"
        case .evening: "evening"
        case .area(let area): "area-\(area.id)"
        case .project(let project): "project-\(project.id)"
        case .heading(let heading): "heading-\(heading.id)"
        case .day(let day): "day-\(day)"
        case .month(let year, let month): "month-\(year)-\(month)"
        case .later: "later"
        case .completed: "completed"
        }
    }
}

/// Things' list semantics computed over a snapshot.
public struct Lists: Sendable {
    public let snapshot: Snapshot
    public let today: Day
    /// Completed items that should stay visible in their lists for now.
    public let keep: Set<UUID>

    public init(snapshot: Snapshot, today: Day, keep: Set<UUID> = []) {
        self.snapshot = snapshot
        self.today = today
        self.keep = keep
    }

    // MARK: - Predicates

    func isLive(_ todo: ToDo) -> Bool {
        guard !todo.isTrashed else { return false }
        if let projectID = todo.projectID, let project = snapshot.projects[projectID], project.isTrashed { return false }
        return todo.isOpen || keep.contains(todo.id)
    }

    func isLive(_ project: Project) -> Bool {
        !project.isTrashed && (project.isOpen || keep.contains(project.id))
    }

    /// The project's "when" — to-dos in a someday or future project aren't actionable.
    func projectIsActive(_ todo: ToDo) -> Bool {
        guard let projectID = todo.projectID, let project = snapshot.projects[projectID] else { return true }
        if project.start == .someday { return false }
        if let date = project.startDate, date > today { return false }
        return true
    }

    public func isInInbox(_ todo: ToDo) -> Bool {
        todo.start == .inbox && todo.projectID == nil && todo.areaID == nil
    }

    public func isInToday<T: Schedulable>(_ item: T) -> Bool {
        if item.isScheduled(onOrBefore: today) { return true }
        if let deadline = item.deadline, deadline <= today { return true }
        return false
    }

    public func isOverdue<T: Schedulable>(_ item: T) -> Bool {
        guard item.isOpen, let deadline = item.deadline else { return false }
        return deadline < today
    }

    // MARK: - Lists

    public func items(for list: ListID) -> [ItemGroup] {
        switch list {
        case .inbox: inbox()
        case .today: todayList()
        case .upcoming: upcoming()
        case .anytime: anytime()
        case .someday: someday()
        case .logbook: logbook()
        case .trash: trash()
        case .project(let id): project(id)
        case .area(let id): area(id)
        case .tag(let id): tagged(id)
        }
    }

    public func inbox() -> [ItemGroup] {
        let todos = snapshot.todos.values.filter { isLive($0) && isInInbox($0) }.sorted(by: Snapshot.byIndex)
        return [ItemGroup(header: .none, items: todos.map(Item.todo))]
    }

    public func todayList() -> [ItemGroup] {
        let projects = snapshot.projects.values.filter { isLive($0) && isInToday($0) }
        let todos = snapshot.todos.values.filter { isLive($0) && !isInInbox($0) && isInToday($0) }
        let byToday: (any Schedulable, any Schedulable) -> Bool = { a, b in
            a.todayIndex != b.todayIndex ? a.todayIndex < b.todayIndex : a.createdAt < b.createdAt
        }
        let day = (projects.filter { !$0.isEvening } as [any Schedulable]) + todos.filter { !$0.isEvening }
        let evening = (projects.filter(\.isEvening) as [any Schedulable]) + todos.filter(\.isEvening)
        var groups = [ItemGroup(header: .none, items: day.sorted(by: byToday).map(Self.item))]
        if !evening.isEmpty {
            groups.append(ItemGroup(header: .evening, items: evening.sorted(by: byToday).map(Self.item)))
        }
        return groups
    }

    private static func item(_ value: any Schedulable) -> Item {
        if let todo = value as? ToDo { return .todo(todo) }
        return .project(value as! Project)
    }

    public func upcoming() -> [ItemGroup] {
        var byDay: [Day: [Item]] = [:]
        for project in snapshot.projects.values where isLive(project) && project.isOpen {
            if let date = project.startDate, date > today { byDay[date, default: []].append(.project(project)) }
        }
        for todo in snapshot.todos.values where isLive(todo) && todo.isOpen && todo.start != .inbox {
            if let date = todo.startDate, date > today { byDay[date, default: []].append(.todo(todo)) }
        }
        return byDay.keys.sorted().map { day in
            let items = byDay[day]!.sorted { a, b in
                switch (a, b) {
                case (.project, .todo): return true
                case (.todo, .project): return false
                case (.todo(let x), .todo(let y)): return x.todayIndex != y.todayIndex ? x.todayIndex < y.todayIndex : Snapshot.byIndex(x, y)
                default: return a.title < b.title
                }
            }
            return ItemGroup(header: .day(day), items: items)
        }
    }

    /// Actionable to-dos grouped the way Things does: loose ones, then by area and project.
    public func anytime() -> [ItemGroup] {
        let todos = snapshot.todos.values.filter { todo in
            isLive(todo) && todo.start == .anytime && !(todo.startDate.map { $0 > today } ?? false) && projectIsActive(todo)
        }
        return grouped(todos)
    }

    public func someday() -> [ItemGroup] {
        let todos = snapshot.todos.values.filter { isLive($0) && $0.start == .someday && $0.startDate == nil }
        var groups = grouped(todos)
        let projects = snapshot.projects.values.filter { isLive($0) && $0.start == .someday && $0.startDate == nil }.sorted(by: Snapshot.byIndex)
        if !projects.isEmpty {
            groups.insert(ItemGroup(header: .none, items: projects.map(Item.project)), at: 0)
        }
        return groups
    }

    /// Groups to-dos into loose / per area / per project.
    func grouped(_ todos: [ToDo]) -> [ItemGroup] {
        var loose: [ToDo] = []
        var byProject: [UUID: [ToDo]] = [:]
        var byArea: [UUID: [ToDo]] = [:]
        for todo in todos {
            if let projectID = todo.projectID, snapshot.projects[projectID] != nil {
                byProject[projectID, default: []].append(todo)
            } else if let areaID = todo.areaID, snapshot.areas[areaID] != nil {
                byArea[areaID, default: []].append(todo)
            } else {
                loose.append(todo)
            }
        }

        var groups: [ItemGroup] = []
        if !loose.isEmpty {
            groups.append(ItemGroup(header: .none, items: loose.sorted(by: Snapshot.byIndex).map(Item.todo)))
        }
        func appendProjects(in areaID: UUID?) {
            let projects = snapshot.projects.values.filter { $0.areaID == areaID && byProject[$0.id] != nil }.sorted(by: Snapshot.byIndex)
            for project in projects {
                groups.append(ItemGroup(header: .project(project), items: sortedInProject(byProject[project.id]!, project.id).map(Item.todo)))
            }
        }
        appendProjects(in: nil)
        for area in snapshot.areas.values.sorted(by: Snapshot.byIndex) {
            if let todos = byArea[area.id] {
                groups.append(ItemGroup(header: .area(area), items: todos.sorted(by: Snapshot.byIndex).map(Item.todo)))
            }
            appendProjects(in: area.id)
        }
        return groups
    }

    /// Sorts to-dos in project order: unheaded first, then by heading.
    func sortedInProject(_ todos: [ToDo], _ projectID: UUID) -> [ToDo] {
        let headingOrder = Dictionary(uniqueKeysWithValues: snapshot.headings(in: projectID).enumerated().map { ($1.id, $0) })
        return todos.sorted { a, b in
            let ha = a.headingID.flatMap { headingOrder[$0] } ?? -1
            let hb = b.headingID.flatMap { headingOrder[$0] } ?? -1
            return ha != hb ? ha < hb : Snapshot.byIndex(a, b)
        }
    }

    public func logbook() -> [ItemGroup] {
        var entries: [(Date, Item)] = []
        for todo in snapshot.todos.values where !todo.isOpen && !todo.isTrashed && !keep.contains(todo.id) {
            entries.append((todo.completedAt ?? todo.createdAt, .todo(todo)))
        }
        for project in snapshot.projects.values where !project.isOpen && !project.isTrashed && !keep.contains(project.id) {
            entries.append((project.completedAt ?? project.createdAt, .project(project)))
        }
        entries.sort { $0.0 > $1.0 }
        var groups: [ItemGroup] = []
        for (date, item) in entries {
            let day = Day(date)
            if groups.last?.header == .day(day) {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(ItemGroup(header: .day(day), items: [item]))
            }
        }
        return groups
    }

    public func trash() -> [ItemGroup] {
        var items: [(Date, Item)] = []
        for area in snapshot.areas.values where area.isTrashed { items.append((area.createdAt, .area(area))) }
        for project in snapshot.projects.values where project.isTrashed && !(project.areaID.flatMap { snapshot.areas[$0]?.isTrashed } ?? false) {
            items.append((project.createdAt, .project(project)))
        }
        for todo in snapshot.todos.values where todo.isTrashed {
            // Items trashed along with their container show up under it, not on their own.
            if let projectID = todo.projectID, snapshot.projects[projectID]?.isTrashed == true { continue }
            if let areaID = todo.areaID, snapshot.areas[areaID]?.isTrashed == true { continue }
            items.append((todo.createdAt, .todo(todo)))
        }
        return [ItemGroup(header: .none, items: items.sorted { $0.0 > $1.0 }.map(\.1))]
    }

    /// A project's to-dos: unheaded ones first, then each heading (even empty ones),
    /// then someday to-dos in "Later". Completed ones are left to `loggedItems(in:)`.
    public func project(_ id: UUID) -> [ItemGroup] {
        let todos = snapshot.todos.values.filter { $0.projectID == id && isLive($0) }
        let headings = snapshot.headings(in: id)
        let headingIDs = Set(headings.map(\.id))
        let active = todos.filter { $0.start != .someday || $0.startDate != nil }
        var groups = [ItemGroup(header: .none, items: active.filter { $0.headingID.map { !headingIDs.contains($0) } ?? true }.sorted(by: Snapshot.byIndex).map(Item.todo))]
        for heading in headings where !heading.isArchived {
            groups.append(ItemGroup(header: .heading(heading), items: active.filter { $0.headingID == heading.id }.sorted(by: Snapshot.byIndex).map(Item.todo)))
        }
        let later = todos.filter { $0.start == .someday && $0.startDate == nil }
        if !later.isEmpty {
            groups.append(ItemGroup(header: .later, items: sortedInProject(later, id).map(Item.todo)))
        }
        return groups
    }

    /// Completed and canceled to-dos in a project or area, newest first.
    public func loggedItems(in list: ListID) -> [ToDo] {
        snapshot.todos.values.filter { todo in
            guard !todo.isOpen, !todo.isTrashed, !keep.contains(todo.id) else { return false }
            switch list {
            case .project(let id): return todo.projectID == id
            case .area(let id): return todo.areaID == id && todo.projectID == nil
            default: return false
            }
        }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// An area: its projects, then its loose to-dos, then someday to-dos.
    public func area(_ id: UUID) -> [ItemGroup] {
        let projects = snapshot.projects.values.filter { $0.areaID == id && isLive($0) }.sorted(by: Snapshot.byIndex)
        let todos = snapshot.todos.values.filter { $0.areaID == id && $0.projectID == nil && isLive($0) }
        var groups = [
            ItemGroup(header: .none, items: projects.map(Item.project)),
            ItemGroup(header: .none, items: todos.filter { $0.start != .someday || $0.startDate != nil }.sorted(by: Snapshot.byIndex).map(Item.todo)),
        ]
        let later = todos.filter { $0.start == .someday && $0.startDate == nil }
        if !later.isEmpty {
            groups.append(ItemGroup(header: .later, items: later.sorted(by: Snapshot.byIndex).map(Item.todo)))
        }
        return groups
    }

    /// Everything open carrying a tag (or one of its children), grouped like Anytime.
    public func tagged(_ id: UUID) -> [ItemGroup] {
        let family = snapshot.tagFamily(id)
        let todos = snapshot.todos.values.filter { isLive($0) && !snapshot.effectiveTags($0).isDisjoint(with: family) }
        return grouped(todos)
    }

    /// Restricts groups to items carrying the tag (including inherited and child tags).
    public func filter(_ groups: [ItemGroup], tag: UUID?) -> [ItemGroup] {
        guard let tag else { return groups }
        let family = snapshot.tagFamily(tag)
        return groups.compactMap { group in
            let items = group.items.filter { item in
                switch item {
                case .todo(let todo): !snapshot.effectiveTags(todo).isDisjoint(with: family)
                case .project(let project): !snapshot.effectiveTags(project).isDisjoint(with: family)
                default: true
                }
            }
            return items.isEmpty ? nil : ItemGroup(header: group.header, items: items)
        }
    }

    /// Tags used by items in these groups, for the tag filter bar.
    public func tagsUsed(in groups: [ItemGroup]) -> [Tag] {
        var used = Set<UUID>()
        for item in groups.flatMap(\.items) {
            switch item {
            case .todo(let todo): used.formUnion(snapshot.effectiveTags(todo))
            case .project(let project): used.formUnion(snapshot.effectiveTags(project))
            default: break
            }
        }
        return snapshot.tagList.filter { used.contains($0.id) }
    }

    // MARK: - Counts

    public var inboxCount: Int { inbox().reduce(0) { $0 + $1.items.filter { $0.todo?.isOpen == true }.count } }

    public var todayCount: Int {
        todayList().reduce(0) { total, group in total + group.items.filter { $0.todo?.isOpen == true || $0.project?.isOpen == true }.count }
    }

    /// Items in Today whose deadline has passed or is today — Things shows these in red.
    public var todayDueCount: Int {
        snapshot.todos.values.filter { isLive($0) && $0.isOpen && ($0.deadline.map { $0 <= today } ?? false) }.count
    }

    public func openCount(project id: UUID) -> Int {
        snapshot.todos.values.filter { $0.projectID == id && $0.isOpen && !$0.isTrashed }.count
    }

    // MARK: - Search

    /// Quick Find: lists, areas, projects, tags and to-dos matching `query`.
    public func search(_ query: String, includeCompleted: Bool = true) -> [Item] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        func matches(_ text: String) -> Bool {
            let lower = text.lowercased()
            return terms.allSatisfy { lower.contains($0) }
        }
        var results: [(Int, Item)] = []
        for area in snapshot.areas.values where !area.isTrashed && matches(area.title) { results.append((0, .area(area))) }
        for project in snapshot.projects.values where !project.isTrashed && matches(project.title + " " + project.notes) {
            if includeCompleted || project.isOpen { results.append((project.isOpen ? 1 : 4, .project(project))) }
        }
        for tag in snapshot.tags.values where matches(tag.title) { results.append((2, .tag(tag))) }
        for todo in snapshot.todos.values where !todo.isTrashed {
            let checklist = (snapshot.checklists[todo.id] ?? []).map(\.title).joined(separator: " ")
            if matches(todo.title + " " + todo.notes + " " + checklist), includeCompleted || todo.isOpen {
                results.append((todo.isOpen ? 3 : 5, .todo(todo)))
            }
        }
        return results.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1.title.localizedStandardCompare(b.1.title) == .orderedAscending }.map(\.1)
    }
}
