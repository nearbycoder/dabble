import Foundation

/// Typed, indexed view of every live object at one revision.
public struct Snapshot: Sendable {
    public let todos: [UUID: ToDo]
    public let projects: [UUID: Project]
    public let areas: [UUID: Area]
    public let headings: [UUID: Heading]
    public let tags: [UUID: Tag]
    /// Checklist items keyed by to-do, sorted.
    public let checklists: [UUID: [ChecklistItem]]

    init<S: Sequence>(records: S) where S.Element == Record {
        var todos: [UUID: ToDo] = [:]
        var projects: [UUID: Project] = [:]
        var areas: [UUID: Area] = [:]
        var headings: [UUID: Heading] = [:]
        var tags: [UUID: Tag] = [:]
        var checklists: [UUID: [ChecklistItem]] = [:]
        for record in records where !record.values.bool(Key.purged) {
            switch record.kind {
            case .todo: todos[record.id] = ToDo(record: record)
            case .project: projects[record.id] = Project(record: record)
            case .area: areas[record.id] = Area(record: record)
            case .heading: headings[record.id] = Heading(record: record)
            case .tag: tags[record.id] = Tag(record: record)
            case .checklist:
                let item = ChecklistItem(record: record)
                if let todoID = item.todoID, !item.isTrashed { checklists[todoID, default: []].append(item) }
            }
        }
        self.todos = todos
        self.projects = projects
        self.areas = areas
        self.headings = headings
        self.tags = tags
        self.checklists = checklists.mapValues { $0.sorted(by: Self.byIndex) }
    }

    static func byIndex<E: Entity>(_ a: E, _ b: E) -> Bool {
        a.index != b.index ? a.index < b.index : a.createdAt < b.createdAt
    }

    // MARK: - Collections for navigation

    /// Areas in sidebar order.
    public var areaList: [Area] {
        areas.values.filter { !$0.isTrashed }.sorted(by: Self.byIndex)
    }

    /// Open projects in an area (nil = projects without an area), sidebar order.
    public func openProjects(in areaID: UUID?) -> [Project] {
        projects.values.filter { $0.areaID == areaID && $0.isOpen && !$0.isTrashed }.sorted(by: Self.byIndex)
    }

    /// Top-level tags first, each followed by its children.
    public var tagList: [Tag] {
        let live = tags.values.sorted(by: Self.byIndex)
        let roots = live.filter { $0.parentID == nil || tags[$0.parentID!] == nil }
        var result: [Tag] = []
        func visit(_ tag: Tag, depth: Int) {
            guard depth < 8 else { return }
            result.append(tag)
            for child in live where child.parentID == tag.id { visit(child, depth: depth + 1) }
        }
        roots.forEach { visit($0, depth: 0) }
        return result
    }

    public func tagDepth(_ tag: Tag) -> Int {
        var depth = 0
        var current = tag.parentID
        while let id = current, let parent = tags[id], depth < 8 {
            depth += 1
            current = parent.parentID
        }
        return depth
    }

    /// A tag and all of its descendants.
    public func tagFamily(_ id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for tag in tags.values where tag.parentID == next && !result.contains(tag.id) {
                result.insert(tag.id)
                frontier.append(tag.id)
            }
        }
        return result
    }

    /// Own tags plus those inherited from the project and area, like Things.
    public func effectiveTags(_ todo: ToDo) -> Set<UUID> {
        var result = Set(todo.tagIDs)
        if let projectID = todo.projectID, let project = projects[projectID] {
            result.formUnion(project.tagIDs)
            if let areaID = project.areaID, let area = areas[areaID] { result.formUnion(area.tagIDs) }
        }
        if let areaID = todo.areaID, let area = areas[areaID] { result.formUnion(area.tagIDs) }
        return result
    }

    public func effectiveTags(_ project: Project) -> Set<UUID> {
        var result = Set(project.tagIDs)
        if let areaID = project.areaID, let area = areas[areaID] { result.formUnion(area.tagIDs) }
        return result
    }

    public func tags(of item: Item) -> [Tag] {
        let ids: [UUID]
        switch item {
        case .todo(let todo): ids = todo.tagIDs
        case .project(let project): ids = project.tagIDs
        case .area(let area): ids = area.tagIDs
        default: ids = []
        }
        return ids.compactMap { tags[$0] }
    }

    public func headings(in projectID: UUID) -> [Heading] {
        headings.values.filter { $0.projectID == projectID && !$0.isTrashed }.sorted(by: Self.byIndex)
    }

    /// The area a to-do belongs to, directly or through its project.
    public func area(of todo: ToDo) -> Area? {
        if let areaID = todo.areaID { return areas[areaID] }
        if let projectID = todo.projectID, let areaID = projects[projectID]?.areaID { return areas[areaID] }
        return nil
    }

    /// Completed and total to-dos in a project (canceled ones count as done).
    public func progress(of projectID: UUID) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for todo in todos.values where todo.projectID == projectID && !todo.isTrashed {
            total += 1
            if !todo.isOpen { done += 1 }
        }
        return (done, total)
    }

    public func checklistProgress(of todoID: UUID) -> (done: Int, total: Int) {
        let items = checklists[todoID] ?? []
        return (items.filter(\.isDone).count, items.count)
    }
}

/// Anything that can appear as a row.
public enum Item: Identifiable, Hashable, Sendable {
    case todo(ToDo)
    case project(Project)
    case area(Area)
    case tag(Tag)
    case heading(Heading)

    public var id: UUID {
        switch self {
        case .todo(let x): x.id
        case .project(let x): x.id
        case .area(let x): x.id
        case .tag(let x): x.id
        case .heading(let x): x.id
        }
    }

    public var title: String {
        switch self {
        case .todo(let x): x.title
        case .project(let x): x.title
        case .area(let x): x.title
        case .tag(let x): x.title
        case .heading(let x): x.title
        }
    }

    public var todo: ToDo? {
        if case .todo(let todo) = self { return todo }
        return nil
    }

    public var project: Project? {
        if case .project(let project) = self { return project }
        return nil
    }
}
