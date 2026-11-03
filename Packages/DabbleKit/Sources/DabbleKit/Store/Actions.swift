import CryptoKit
import Foundation

/// Where to move a to-do or project.
public enum Destination: Hashable, Sendable {
    case inbox
    /// Out of any project or area, without changing "when".
    case none
    case area(UUID)
    case project(UUID, heading: UUID? = nil)
}

/// High-level operations with Things semantics. UIs should prefer these over
/// raw writes so that every client behaves the same way.
public extension DabbleStore {
    // MARK: - Creating

    /// Adds a to-do the way Things does when you press ⌘N in a list.
    @discardableResult
    func addToDo(_ title: String, notes: String = "", in list: ListID? = .inbox, heading: UUID? = nil, when: When? = nil, today: Day = .today) -> ToDo {
        var todo = ToDo(title: title)
        todo.notes = notes
        let snapshot = snapshot
        switch list {
        case .inbox?, .logbook?, .trash?, nil:
            todo.start = .inbox
        case .today?:
            todo.start = .anytime
            todo.startDate = today
            todo.todayIndex = (snapshot.todos.values.map(\.todayIndex).max() ?? 0) + 1
        case .upcoming?:
            todo.start = .anytime
            todo.startDate = today.adding(days: 1)
        case .anytime?:
            todo.start = .anytime
        case .someday?:
            todo.start = .someday
        case .project(let id)?:
            todo.start = .anytime
            todo.projectID = id
            todo.headingID = heading
        case .area(let id)?:
            todo.start = .anytime
            todo.areaID = id
        case .tag(let id)?:
            todo.start = .anytime
            todo.tagIDs = [id]
        }
        let siblings = snapshot.todos.values.filter { $0.projectID == todo.projectID && $0.areaID == todo.areaID && $0.headingID == todo.headingID }
        todo.index = (siblings.map(\.index).max() ?? 0) + 1
        if let when { apply(when, to: &todo, today: today) }
        save(todo)
        return todo
    }

    @discardableResult
    func addProject(_ title: String, area: UUID? = nil, when: When? = nil) -> Project {
        var project = Project(title: title)
        project.areaID = area
        project.index = (snapshot.projects.values.filter { $0.areaID == area }.map(\.index).max() ?? 0) + 1
        if let when { apply(when, to: &project, today: .today) }
        save(project)
        return project
    }

    @discardableResult
    func addArea(_ title: String) -> Area {
        var area = Area(title: title)
        area.index = (snapshot.areas.values.map(\.index).max() ?? 0) + 1
        save(area)
        return area
    }

    @discardableResult
    func addHeading(_ title: String, in project: UUID) -> Heading {
        var heading = Heading(title: title, projectID: project)
        heading.index = (snapshot.headings(in: project).map(\.index).max() ?? 0) + 1
        save(heading)
        return heading
    }

    @discardableResult
    func addTag(_ title: String, parent: UUID? = nil) -> Tag {
        if let existing = snapshot.tags.values.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame && $0.parentID == parent }) {
            return existing
        }
        var tag = Tag(title: title, parentID: parent)
        tag.index = (snapshot.tags.values.map(\.index).max() ?? 0) + 1
        save(tag)
        return tag
    }

    @discardableResult
    func addChecklistItem(_ title: String, to todo: UUID, after: UUID? = nil) -> ChecklistItem {
        var item = ChecklistItem(title: title, todoID: todo)
        let items = snapshot.checklists[todo] ?? []
        if let after, let position = items.firstIndex(where: { $0.id == after }) {
            let next = position + 1 < items.count ? items[position + 1].index : items[position].index + 2
            item.index = (items[position].index + next) / 2
        } else {
            item.index = (items.map(\.index).max() ?? 0) + 1
        }
        save(item)
        return item
    }

    // MARK: - Completing

    /// Marks to-dos or projects completed, canceled or open again.
    func setStatus(_ ids: [UUID], _ status: Status, today: Day = .today) {
        batch {
            for id in ids {
                if var todo = self.todo(id) {
                    guard todo.status != status else { continue }
                    let wasOpen = todo.isOpen
                    todo.status = status
                    todo.completedAt = status == .open ? nil : Date()
                    if status != .open && wasOpen, let rule = todo.repeatRule {
                        spawnNextInstance(of: todo, rule: rule, today: today)
                        todo.repeatRule = nil
                    }
                    save(todo)
                    if status != .open { noteCompleted(id) }
                } else if var project = self.project(id) {
                    guard project.status != status else { continue }
                    project.status = status
                    project.completedAt = status == .open ? nil : Date()
                    save(project)
                    if status != .open {
                        // Like Things: finishing a project finishes what's left in it.
                        for todo in snapshot.todos.values where todo.projectID == id && todo.isOpen && !todo.isTrashed {
                            var done = todo
                            done.status = status
                            done.completedAt = Date()
                            save(done)
                        }
                        noteCompleted(id)
                    }
                }
            }
        }
    }

    func toggleCompleted(_ id: UUID) {
        let status = todo(id)?.status ?? project(id)?.status ?? .open
        setStatus([id], status == .open ? .completed : .open)
    }

    func toggleChecklistItem(_ id: UUID) {
        update(ChecklistItem.self, id) { $0.isDone.toggle() }
    }

    /// Repeating to-dos: completing one instance creates the next, with an id
    /// derived from the series and date so two devices completing the same
    /// instance offline create the *same* next instance instead of two.
    private func spawnNextInstance(of todo: ToDo, rule: RepeatRule, today: Day) {
        guard let nextDay = rule.next(after: todo.startDate, completedOn: today) else { return }
        let series = todo.repeatSeries ?? todo.id
        let nextID = Self.derivedID(series.uuidString, nextDay.description)
        guard records[nextID] == nil else { return }

        var next = ToDo(id: nextID, values: todo.values)
        next.status = .open
        next.completedAt = nil
        next.start = .anytime
        next.startDate = nextDay
        next.repeatRule = rule
        next.repeatSeries = series
        if let deadline = todo.deadline {
            let offset = (todo.startDate ?? today).days(until: deadline)
            next.deadline = nextDay.adding(days: offset)
        }
        save(next)
        for (position, item) in (snapshot.checklists[todo.id] ?? []).enumerated() {
            var copy = ChecklistItem(title: item.title, todoID: nextID, id: Self.derivedID(nextID.uuidString, String(position)))
            copy.index = item.index
            save(copy)
        }
    }

    static func derivedID(_ parts: String...) -> UUID {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Scheduling

    /// Applies a "When" to to-dos and projects.
    func schedule(_ ids: [UUID], _ when: When, today: Day = .today) {
        batch {
            let topOfToday = (snapshot.todos.values.map(\.todayIndex).min() ?? 0) - 1
            for (offset, id) in ids.enumerated() {
                if var todo = self.todo(id) {
                    let wasToday = todo.isScheduled(onOrBefore: today)
                    apply(when, to: &todo, today: today)
                    if !wasToday && todo.isScheduled(onOrBefore: today) { todo.todayIndex = topOfToday - Double(ids.count - offset) }
                    save(todo)
                } else if var project = self.project(id) {
                    apply(when == .inbox ? .anytime : when, to: &project, today: today)
                    save(project)
                }
            }
        }
    }

    internal func apply<T: Schedulable>(_ when: When, to item: inout T, today: Day) {
        switch when {
        case .today, .evening:
            item.start = .anytime
            item.startDate = today
            item.isEvening = when == .evening
        case .anytime:
            item.start = .anytime
            item.startDate = nil
            item.isEvening = false
        case .someday:
            item.start = .someday
            item.startDate = nil
            item.isEvening = false
        case .date(let day):
            item.start = .anytime
            item.startDate = day
            item.isEvening = false
        case .inbox:
            if let todo = item as? ToDo, todo.projectID == nil, todo.areaID == nil {
                item.start = .inbox
                item.startDate = nil
                item.isEvening = false
            }
        }
    }

    func setDeadline(_ ids: [UUID], _ day: Day?) {
        batch {
            for id in ids {
                if var todo = self.todo(id) {
                    todo.deadline = day
                    save(todo)
                } else if var project = self.project(id) {
                    project.deadline = day
                    save(project)
                }
            }
        }
    }

    /// Sets a reminder time (minutes after midnight) on the item's "when" day.
    func setReminder(_ id: UUID, minutes: Int?, today: Day = .today) {
        if var todo = self.todo(id) {
            todo.reminder = minutes
            if minutes != nil && todo.startDate == nil { apply(.today, to: &todo, today: today) }
            save(todo)
        } else if var project = self.project(id) {
            project.reminder = minutes
            if minutes != nil && project.startDate == nil { apply(.today, to: &project, today: today) }
            save(project)
        }
    }

    func setRepeat(_ id: UUID, _ rule: RepeatRule?, today: Day = .today) {
        update(ToDo.self, id) { todo in
            todo.repeatRule = rule
            if rule != nil {
                if todo.repeatSeries == nil { todo.repeatSeries = todo.id }
                if todo.startDate == nil { apply(.today, to: &todo, today: today) }
            }
        }
    }

    // MARK: - Organizing

    func move(_ ids: [UUID], to destination: Destination) {
        batch {
            for id in ids {
                if var todo = self.todo(id) {
                    switch destination {
                    case .inbox:
                        todo.projectID = nil
                        todo.headingID = nil
                        todo.areaID = nil
                        todo.start = .inbox
                        todo.startDate = nil
                        todo.isEvening = false
                    case .none:
                        todo.projectID = nil
                        todo.headingID = nil
                        todo.areaID = nil
                    case .area(let area):
                        todo.projectID = nil
                        todo.headingID = nil
                        todo.areaID = area
                    case .project(let project, let heading):
                        todo.projectID = project
                        todo.headingID = heading
                        todo.areaID = nil
                    }
                    if destination != .inbox && todo.start == .inbox { todo.start = .anytime }
                    save(todo)
                } else if var project = self.project(id) {
                    switch destination {
                    case .area(let area): project.areaID = area
                    case .inbox, .none, .project: project.areaID = nil
                    }
                    save(project)
                }
            }
        }
    }

    func setTags(_ id: UUID, _ tags: [UUID]) {
        if var todo = self.todo(id) {
            todo.tagIDs = tags
            save(todo)
        } else if var project = self.project(id) {
            project.tagIDs = tags
            save(project)
        } else if var area = self.area(id) {
            area.tagIDs = tags
            save(area)
        }
    }

    /// Adds the tag to all items, or removes it if every item already has it.
    func toggleTag(_ tag: UUID, on ids: [UUID]) {
        let current = ids.map { todo($0)?.tagIDs ?? project($0)?.tagIDs ?? area($0)?.tagIDs ?? [] }
        let allHave = current.allSatisfy { $0.contains(tag) }
        batch {
            for (id, tags) in zip(ids, current) {
                setTags(id, allHave ? tags.filter { $0 != tag } : (tags.contains(tag) ? tags : tags + [tag]))
            }
        }
    }

    /// Converts a to-do into a project; its checklist items become to-dos.
    @discardableResult
    func convertToProject(_ id: UUID) -> Project? {
        guard let todo = self.todo(id) else { return nil }
        return batch {
            var project = Project(title: todo.title)
            project.notes = todo.notes
            project.areaID = todo.areaID ?? todo.projectID.flatMap { self.project($0)?.areaID }
            project.tagIDs = todo.tagIDs
            project.deadline = todo.deadline
            project.start = todo.start == .inbox ? .anytime : todo.start
            project.startDate = todo.startDate
            project.index = (snapshot.projects.values.map(\.index).max() ?? 0) + 1
            save(project)
            for item in snapshot.checklists[id] ?? [] {
                var child = ToDo(title: item.title)
                child.start = .anytime
                child.projectID = project.id
                child.index = item.index
                if item.isDone {
                    child.status = .completed
                    child.completedAt = Date()
                }
                save(child)
            }
            write(id, kind: .todo, [Key.purged: .bool(true)])
            return project
        }
    }

    /// Reorders items so they appear in `ordered`, touching as few as possible.
    ///
    /// Items on the longest run that is already in order keep their index;
    /// only the others get new ones, spaced between their neighbours. Fewer
    /// writes means concurrent reorders on other devices clobber less.
    func reorder(_ ordered: [UUID], key: String = Key.index) {
        let values = ordered.map { records[$0]?.values.double(key) ?? 0 }
        let keep = Self.longestIncreasingRun(values)
        batch {
            var previous = -Double.infinity
            var position = 0
            while position < ordered.count {
                if keep.contains(position) {
                    previous = values[position]
                    position += 1
                    continue
                }
                var end = position
                while end < ordered.count && !keep.contains(end) { end += 1 }
                let next: Double? = end < ordered.count ? values[end] : nil
                let count = Double(end - position)
                let low = previous.isFinite ? previous : (next.map { $0 - count - 1 } ?? 0)
                let high = next ?? (low + count + 1)
                for offset in position..<end {
                    let value = low + (high - low) * Double(offset - position + 1) / (count + 1)
                    if let kind = records[ordered[offset]]?.kind { write(ordered[offset], kind: kind, [key: .number(value)]) }
                    previous = value
                }
                position = end
            }
        }
    }

    /// Positions of a longest strictly increasing subsequence.
    static func longestIncreasingRun(_ values: [Double]) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        var tails: [Int] = []
        var parent = [Int](repeating: -1, count: values.count)
        for (i, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { parent[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var result = Set<Int>()
        var current = tails.last ?? -1
        while current >= 0 {
            result.insert(current)
            current = parent[current]
        }
        return result
    }

    // MARK: - Deleting

    /// Moves items to the Trash. Projects and areas take their contents with them.
    func trash(_ ids: [UUID]) {
        setTrashed(ids, true)
    }

    func restore(_ ids: [UUID]) {
        setTrashed(ids, false)
    }

    private func setTrashed(_ ids: [UUID], _ trashed: Bool) {
        let snapshot = snapshot
        batch {
            for id in ids {
                guard let kind = records[id]?.kind else { continue }
                write(id, kind: kind, [Key.trashed: .bool(trashed)])
                switch kind {
                case .project:
                    for todo in snapshot.todos.values where todo.projectID == id { write(todo.id, kind: .todo, [Key.trashed: .bool(trashed)]) }
                    for heading in snapshot.headings.values where heading.projectID == id { write(heading.id, kind: .heading, [Key.trashed: .bool(trashed)]) }
                case .area:
                    for project in snapshot.projects.values where project.areaID == id { setTrashed([project.id], trashed) }
                    for todo in snapshot.todos.values where todo.areaID == id { write(todo.id, kind: .todo, [Key.trashed: .bool(trashed)]) }
                case .heading:
                    for todo in snapshot.todos.values where todo.headingID == id { write(todo.id, kind: .todo, [Key.trashed: .bool(trashed)]) }
                default:
                    break
                }
            }
        }
    }

    /// Permanently deletes everything in the Trash on every synced device.
    func emptyTrash() {
        let doomed = records.values.filter { $0.values.bool(Key.trashed) && !$0.values.bool(Key.purged) }
        batch {
            for record in doomed { purge(record.id) }
        }
    }

    /// Deletes an item for good (tags, headings and checklist items skip the Trash).
    func delete(_ id: UUID) {
        batch {
            if let kind = records[id]?.kind, kind == .todo {
                for item in snapshot.checklists[id] ?? [] { purge(item.id) }
            }
            if let tag = self.tag(id) {
                for child in snapshot.tags.values where child.parentID == tag.id { delete(child.id) }
            }
            purge(id)
        }
    }

    /// Leaves a tombstone so the deletion syncs, and drops the content.
    private func purge(_ id: UUID) {
        guard let record = records[id] else { return }
        var values: [String: Value] = [Key.purged: .bool(true)]
        for key in record.fields.keys where key != Key.purged && key != Key.createdAt { values[key] = .null }
        write(id, kind: record.kind, values, undoable: false)
    }
}
