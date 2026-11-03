import AppKit
import DabbleKit
import SwiftUI

enum PickerKind: String, Identifiable {
    case when, deadline, tags, move, repeatRule, reminder
    var id: String { rawValue }
}

/// A picker popover anchored to a row (or the expanded editor's button).
struct PopoverRequest: Equatable {
    var kind: PickerKind
    var ids: [UUID]
    var anchor: UUID
}

/// Where a dragged row would land.
struct DropIndicator: Equatable {
    var id: UUID
    var after: Bool
}

/// Everything one window shows: the list, the selection, what's expanded.
/// Menu commands reach it through `FocusedValues.windowState`.
@MainActor
@Observable
final class WindowState {
    let model: AppModel

    var list: ListID? = .today {
        didSet { if list != oldValue { listDidChange() } }
    }
    var selection: Set<UUID> = []
    private(set) var anchor: UUID?
    private(set) var cursor: UUID?
    private(set) var editingID: UUID?
    var tagFilter: UUID?
    var popover: PopoverRequest?
    /// Non-nil while Quick Find is open; the initial query.
    var quickFindQuery: String?
    var showLogged = false
    var focusHeaderTitle = false
    var focusHeadingID: UUID?
    var listFocusRequest = 0
    var editorFocusRequest = 0
    var checklistRequest = 0
    var scrollTarget: UUID?
    var dropIndicator: DropIndicator?
    /// Late drag updates arrive after a drop; ignore them for a moment.
    @ObservationIgnored var suppressDropIndicatorUntil = Date.distantPast
    @ObservationIgnored private var createdForEditing: UUID?
    /// A heading just named; the next new to-do goes into it.
    @ObservationIgnored var pendingHeading: UUID?
    /// The AppKit window showing this state.
    @ObservationIgnored weak var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var store: DabbleStore { model.store }
    var current: ListID { list ?? .today }

    private func listDidChange() {
        finishEditing(refocus: false)
        selection = []
        anchor = nil
        cursor = nil
        tagFilter = nil
        showLogged = false
        popover = nil
        dropIndicator = nil
        pendingHeading = nil
        if !focusHeaderTitle { listFocusRequest += 1 }
    }

    // MARK: - Contents

    func groups(in lists: Lists) -> [ItemGroup] {
        lists.filter(lists.items(for: current), tag: tagFilter)
    }

    func loggedItems(in lists: Lists) -> [ToDo] {
        switch current {
        case .project, .area: lists.loggedItems(in: current)
        default: []
        }
    }

    /// Row ids in on-screen order.
    func visibleIDs() -> [UUID] {
        let lists = model.lists
        var ids = groups(in: lists).flatMap { $0.items.map(\.id) }
        if showLogged { ids += loggedItems(in: lists).map(\.id) }
        return ids
    }

    /// What commands act on: the open to-do, or the selection in list order.
    var targets: [UUID] {
        if let editingID { return [editingID] }
        guard !selection.isEmpty else { return [] }
        let ordered = visibleIDs().filter(selection.contains)
        return ordered + selection.filter { !ordered.contains($0) }
    }

    var hasTargets: Bool { editingID != nil || !selection.isEmpty }

    /// For context menus: the selection if the row is part of it, else just the row.
    func targets(including id: UUID) -> [UUID] {
        selection.contains(id) ? targets : [id]
    }

    var targetsAreToDos: Bool {
        let ids = targets
        return !ids.isEmpty && ids.allSatisfy { store.todo($0) != nil }
    }

    var canAddToDo: Bool { current != .logbook && current != .trash }

    // MARK: - Selection

    func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if let editingID, editingID != id { finishEditing(refocus: false) }
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
            cursor = id
        } else if flags.contains(.shift), let anchor {
            let order = visibleIDs()
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                selection = Set(order[min(a, b)...max(a, b)])
                cursor = id
            } else {
                select(id)
            }
        } else {
            select(id)
        }
        listFocusRequest += 1
    }

    func select(_ id: UUID) {
        pendingHeading = nil
        selection = [id]
        anchor = id
        cursor = id
    }

    func clearSelection() {
        finishEditing()
        selection = []
        anchor = nil
        cursor = nil
    }

    func selectAll() {
        finishEditing()
        let ids = visibleIDs()
        selection = Set(ids)
        anchor = ids.first
        cursor = ids.last
    }

    func moveCursor(by delta: Int, extend: Bool) {
        let order = visibleIDs()
        guard !order.isEmpty else { return }
        let index: Int
        if let cursor, let current = order.firstIndex(of: cursor) {
            index = max(0, min(order.count - 1, current + delta))
        } else {
            index = delta > 0 ? 0 : order.count - 1
        }
        let id = order[index]
        if extend, let anchor, let a = order.firstIndex(of: anchor) {
            selection = Set(order[min(a, index)...max(a, index)])
            cursor = id
        } else {
            select(id)
        }
        scrollTarget = id
    }

    // MARK: - Editing

    /// Expands a to-do in place, or opens a project/area.
    func open(_ id: UUID) {
        if store.todo(id) != nil {
            guard current != .trash else { return }
            if editingID != id { finishEditing(refocus: false) }
            select(id)
            editingID = id
            editorFocusRequest += 1
        } else if store.project(id) != nil {
            list = .project(id)
        } else if store.area(id) != nil {
            list = .area(id)
        }
    }

    func finishEditing(refocus: Bool = true) {
        guard let id = editingID else { return }
        editingID = nil
        if popover?.anchor == id { popover = nil }
        let snapshot = store.snapshot
        for item in snapshot.checklists[id] ?? [] where item.title.trimmingCharacters(in: .whitespaces).isEmpty {
            store.delete(item.id)
        }
        if id == createdForEditing, let todo = store.todo(id),
           todo.title.trimmingCharacters(in: .whitespaces).isEmpty, todo.notes.isEmpty,
           (store.snapshot.checklists[id] ?? []).isEmpty {
            store.delete(id)
            selection.remove(id)
        }
        createdForEditing = nil
        if refocus { listFocusRequest += 1 }
    }

    // MARK: - Item actions

    private var reorderKey: String {
        current == .today || current == .upcoming ? Key.todayIndex : Key.index
    }

    func toggleComplete(_ ids: [UUID]? = nil) {
        let ids = ids ?? targets
        guard !ids.isEmpty else { return }
        let allDone = ids.allSatisfy { store.status(of: $0) == .completed }
        if !allDone, let editingID, ids.contains(editingID) { finishEditing() }
        withAnimation(.snappy) { store.setStatus(ids, allDone ? .open : .completed, today: model.today) }
        nameUndo(allDone ? "Mark as Open" : "Complete")
    }

    func toggleCanceled(_ ids: [UUID]? = nil) {
        let ids = ids ?? targets
        guard !ids.isEmpty else { return }
        let allCanceled = ids.allSatisfy { store.status(of: $0) == .canceled }
        withAnimation(.snappy) { store.setStatus(ids, allCanceled ? .open : .canceled, today: model.today) }
        nameUndo(allCanceled ? "Mark as Open" : "Cancel")
    }

    func schedule(_ when: When, _ ids: [UUID]? = nil) {
        let ids = ids ?? targets
        guard !ids.isEmpty else { return }
        withAnimation(.snappy) { store.schedule(ids, when, today: model.today) }
        nameUndo("When")
    }

    func showPicker(_ kind: PickerKind, _ ids: [UUID]? = nil) {
        let ids = ids ?? targets
        guard let first = ids.first else { return }
        scrollTarget = first
        popover = PopoverRequest(kind: kind, ids: ids, anchor: first)
    }

    func popoverBinding(_ kind: PickerKind?, anchor: UUID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                guard let request = self?.popover, request.anchor == anchor else { return false }
                return kind == nil || request.kind == kind
            },
            set: { [weak self] presented in
                if !presented, self?.popover?.anchor == anchor { self?.popover = nil }
            }
        )
    }

    func trash(_ ids: [UUID]? = nil) {
        let ids = ids ?? targets
        guard !ids.isEmpty else { return }
        if current == .trash {
            for id in ids { store.delete(id) }
            selection.subtract(ids)
            return
        }
        let order = visibleIDs()
        let next = order.drop { !ids.contains($0) }.first { !ids.contains($0) }
            ?? order.last { !ids.contains($0) }
        editingID = nil
        withAnimation(.snappy) { store.trash(ids) }
        nameUndo("Move to Trash")
        if let next { select(next) } else { selection = [] }
        listFocusRequest += 1
    }

    func restore(_ ids: [UUID]) {
        withAnimation(.snappy) { store.restore(ids) }
        selection.subtract(ids)
    }

    func duplicate() {
        let ids = targets.filter { store.todo($0) != nil }
        guard !ids.isEmpty else { return }
        finishEditing(refocus: false)
        let group = groups(in: model.lists).first { $0.items.contains { $0.id == ids.last } }
        var copies: [UUID] = []
        store.batch {
            for id in ids { if let copy = store.duplicate(id) { copies.append(copy) } }
            if let group, let last = ids.last {
                var order = group.items.map(\.id)
                if let position = order.firstIndex(of: last) {
                    order.insert(contentsOf: copies, at: position + 1)
                    store.reorder(order, key: reorderKey)
                }
            }
        }
        nameUndo("Duplicate")
        selection = Set(copies)
        cursor = copies.last
        anchor = copies.first
    }

    /// ⇧⌘C: opens the to-do (if needed) and starts its checklist.
    func addChecklist() {
        guard let id = targets.first, store.todo(id) != nil else { return }
        if editingID != id { open(id) }
        checklistRequest += 1
    }

    func convertToProject() {
        guard let id = targets.first, store.todo(id) != nil else { return }
        finishEditing(refocus: false)
        if let project = store.convertToProject(id) { list = .project(project.id) }
    }

    func toggleTag(_ tagID: UUID) {
        let ids = targets
        guard !ids.isEmpty else { return }
        store.toggleTag(tagID, on: ids)
    }

    /// ⌃+key toggles the tag whose shortcut is `key` on the selection.
    func toggleTag(shortcut key: String) -> Bool {
        guard hasTargets, let tag = store.snapshot.tagList.first(where: { $0.shortcut?.lowercased() == key.lowercased() }) else { return false }
        toggleTag(tag.id)
        return true
    }

    /// ⌥⌘↑ / ⌥⌘↓: nudges the selected items within their section.
    func moveItems(up: Bool) {
        let ids = targets
        guard !ids.isEmpty, let group = groups(in: model.lists).first(where: { $0.items.contains { $0.id == ids[0] } }) else { return }
        var order = group.items.map(\.id)
        let moving = order.filter(ids.contains)
        guard let first = order.firstIndex(of: moving[0]), let last = order.lastIndex(where: moving.contains) else { return }
        order.removeAll(where: moving.contains)
        let insertAt = up ? max(0, first - 1) : min(order.count, last - moving.count + 2)
        order.insert(contentsOf: moving, at: insertAt)
        withAnimation(.snappy) { store.reorder(order, key: reorderKey) }
        nameUndo("Move")
    }

    /// Names the undo group just registered, e.g. "Undo Complete".
    func nameUndo(_ name: String) {
        store.undoManager?.setActionName(name)
    }

    // MARK: - Creating

    /// ⌘N / Space: a new to-do after the selection, in the selection's section.
    func newToDo(title: String = "") {
        guard canAddToDo else { return }
        let lists = model.lists
        let groups = groups(in: lists)
        let after = editingID ?? cursor.flatMap { selection.contains($0) ? $0 : nil } ?? targets.last
        finishEditing(refocus: false)
        let group = after.flatMap { id in groups.first { $0.items.contains { $0.id == id } } }

        var destination = current
        var heading: UUID?
        var when: When?
        if after == nil, case .project = current, let pending = pendingHeading, store.heading(pending) != nil {
            heading = pending
        }
        pendingHeading = nil
        switch (current, group?.header) {
        case (.project, .heading(let h)?): heading = h.id
        case (.project, .later?), (.area, .later?): when = .someday
        case (.today, .evening?): when = .evening
        case (.upcoming, .day(let day)?): when = .date(day)
        case (_, .project(let project)?): destination = .project(project.id)
        case (_, .area(let area)?): destination = .area(area.id)
        default: break
        }
        if current == .someday { when = .someday }

        let todo = withAnimation(.snappy) { () -> ToDo in
            store.batch {
                let todo = store.addToDo(title, in: destination, heading: heading, when: when, today: model.today)
                var tags = todo.tagIDs
                if case .tag(let tagID) = current, !tags.contains(tagID) { tags.append(tagID) }
                if let tagFilter, !tags.contains(tagFilter) { tags.append(tagFilter) }
                if tags != todo.tagIDs { store.setTags(todo.id, tags) }
                if let after, let group {
                    var order = group.items.map(\.id)
                    if let position = order.firstIndex(of: after) {
                        order.insert(todo.id, at: position + 1)
                        store.reorder(order, key: reorderKey)
                    }
                }
                return todo
            }
        }
        nameUndo("New To-Do")
        beginEditingNew(todo.id)
    }

    /// A new to-do at the end of a heading (from the heading's menu).
    func newToDo(in heading: Heading) {
        guard let projectID = heading.projectID else { return }
        finishEditing(refocus: false)
        let todo = withAnimation(.snappy) { store.addToDo("", in: .project(projectID), heading: heading.id, today: model.today) }
        beginEditingNew(todo.id)
    }

    private func beginEditingNew(_ id: UUID) {
        createdForEditing = id
        select(id)
        editingID = id
        editorFocusRequest += 1
        scrollTarget = id
    }

    func newProject() {
        finishEditing(refocus: false)
        var area: UUID?
        if case .area(let id) = current { area = id }
        let project = store.addProject("", area: area)
        nameUndo("New Project")
        focusHeaderTitle = true
        list = .project(project.id)
    }

    func newArea() {
        finishEditing(refocus: false)
        let area = store.addArea("")
        nameUndo("New Area")
        focusHeaderTitle = true
        list = .area(area.id)
    }

    func newHeading() {
        guard case .project(let projectID) = current else { return }
        finishEditing(refocus: false)
        let heading = withAnimation(.snappy) { store.addHeading("", in: projectID) }
        focusHeadingID = heading.id
        scrollTarget = heading.id
    }

    // MARK: - Navigation

    func navigate(to list: ListID) {
        self.list = list
    }

    /// Goes to the list a to-do lives in and expands it.
    func reveal(_ id: UUID, expand: Bool = true) {
        if store.project(id) != nil { list = .project(id); return }
        if store.area(id) != nil { list = .area(id); return }
        if store.tag(id) != nil { list = .tag(id); return }
        guard let todo = store.todo(id) else { return }
        list = model.lists.home(of: todo)
        if !todo.isOpen { showLogged = true }
        select(id)
        scrollTarget = id
        if expand && todo.isOpen && !todo.isTrashed { open(id) }
    }

    func openQuickFind(_ query: String = "") {
        finishEditing(refocus: false)
        quickFindQuery = query
    }

    // MARK: - Drag & drop

    /// Drops rows before `target` (nil = end) in `group`, applying the group's
    /// meaning: Evening, a heading, a day in Upcoming, a project in Anytime…
    func drop(_ ids: [UUID], before target: UUID?, in group: ItemGroup) {
        let ids = ids.filter { $0 != target }
        guard !ids.isEmpty else { return }
        let snapshot = store.snapshot
        withAnimation(.snappy) {
            store.batch {
                switch (current, group.header) {
                case (.today, .evening):
                    store.schedule(ids.filter { !(snapshot.todos[$0]?.isEvening ?? snapshot.projects[$0]?.isEvening ?? true) }, .evening, today: model.today)
                case (.today, .none):
                    store.schedule(ids.filter { snapshot.todos[$0]?.isEvening ?? snapshot.projects[$0]?.isEvening ?? false }, .today, today: model.today)
                case (.upcoming, .day(let day)):
                    store.schedule(ids.filter { (snapshot.todos[$0]?.startDate ?? snapshot.projects[$0]?.startDate) != day }, .date(day), today: model.today)
                case (.project(let projectID), .heading(let heading)):
                    store.move(ids.filter { snapshot.todos[$0]?.headingID != heading.id || snapshot.todos[$0]?.projectID != projectID }, to: .project(projectID, heading: heading.id))
                case (.project(let projectID), .none):
                    store.move(ids.filter { snapshot.todos[$0]?.headingID != nil || snapshot.todos[$0]?.projectID != projectID }, to: .project(projectID))
                case (.project, .later), (.area, .later):
                    store.schedule(ids, .someday, today: model.today)
                case (_, .project(let project)):
                    store.move(ids.filter { snapshot.todos[$0]?.projectID != project.id }, to: .project(project.id))
                case (_, .area(let area)):
                    store.move(ids.filter { snapshot.todos[$0]?.areaID != area.id }, to: .area(area.id))
                case (.anytime, .none), (.someday, .none):
                    let loose = ids.filter { snapshot.todos[$0]?.projectID != nil || snapshot.todos[$0]?.areaID != nil }
                    if !loose.isEmpty { store.move(loose, to: .none) }
                default:
                    break
                }
                // Leaving a project's "Later" section makes someday to-dos active again.
                if case .project = current, group.header != .later {
                    let someday = ids.filter { snapshot.todos[$0].map { $0.start == .someday && $0.startDate == nil } ?? false }
                    if !someday.isEmpty { store.schedule(someday, .anytime, today: model.today) }
                }
                var order = group.items.map(\.id).filter { !ids.contains($0) }
                let position = target.flatMap { order.firstIndex(of: $0) } ?? order.count
                order.insert(contentsOf: ids, at: position)
                store.reorder(order, key: reorderKey)
            }
        }
        nameUndo("Move")
        selection = Set(ids)
        endDrop()
    }

    func endDrop() {
        dropIndicator = nil
        suppressDropIndicatorUntil = Date().addingTimeInterval(0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.dropIndicator = nil }
    }

    /// Dropping rows onto a list in the sidebar.
    func drop(_ ids: [UUID], on list: ListID) {
        let snapshot = store.snapshot
        let todos = ids.filter { snapshot.todos[$0] != nil }
        let today = model.today
        withAnimation(.snappy) {
            store.batch {
                switch list {
                case .inbox: store.move(todos, to: .inbox)
                case .today: store.schedule(ids, .today, today: today)
                case .upcoming: store.schedule(ids, .date(today.adding(days: 1)), today: today)
                case .anytime: store.schedule(ids, .anytime, today: today)
                case .someday: store.schedule(ids, .someday, today: today)
                case .logbook: store.setStatus(ids, .completed, today: today)
                case .trash: store.trash(ids)
                case .project(let projectID):
                    let projects = ids.filter { snapshot.projects[$0] != nil && $0 != projectID }
                    if !projects.isEmpty { reorderProjects(projects, before: projectID) }
                    store.move(todos, to: .project(projectID))
                case .area(let areaID):
                    let areas = ids.filter { snapshot.areas[$0] != nil && $0 != areaID }
                    if !areas.isEmpty {
                        var order = snapshot.areaList.map(\.id).filter { !areas.contains($0) }
                        order.insert(contentsOf: areas, at: order.firstIndex(of: areaID) ?? order.count)
                        store.reorder(order)
                    }
                    let movable = ids.filter { snapshot.todos[$0] != nil || snapshot.projects[$0] != nil }
                    store.move(movable, to: .area(areaID))
                case .tag(let tagID):
                    for id in ids where !(snapshot.todos[id]?.tagIDs.contains(tagID) ?? true) { store.toggleTag(tagID, on: [id]) }
                }
            }
        }
        if list == .trash || list == .logbook { selection.subtract(ids) }
    }

    /// Sidebar drag: puts projects before `target`, adopting its area.
    private func reorderProjects(_ projects: [UUID], before target: UUID) {
        guard let targetProject = store.project(target) else { return }
        let areaID = targetProject.areaID
        let toMove = projects.filter { store.project($0)?.areaID != areaID }
        if let areaID { store.move(toMove, to: .area(areaID)) } else { store.move(toMove, to: .none) }
        var order = store.snapshot.openProjects(in: areaID).map(\.id).filter { !projects.contains($0) }
        order.insert(contentsOf: projects, at: order.firstIndex(of: target) ?? order.count)
        store.reorder(order)
    }
}

extension FocusedValues {
    @Entry var windowState: WindowState?
}
