import AppKit
import DabbleKit
import SwiftUI

/// What a row needs to know about where it's shown.
struct RowContext {
    var list: ListID
    var group: ItemGroup?
    var lists: Lists

    var today: Day { lists.today }

    var showsTodayStar: Bool {
        switch list {
        case .today, .upcoming, .logbook, .trash: false
        default: true
        }
    }

    var showsWhenDate: Bool {
        switch list {
        case .today, .upcoming, .logbook, .trash: false
        default: true
        }
    }

    var showsSubtitle: Bool {
        switch list {
        case .today, .upcoming, .logbook, .trash, .inbox: true
        default: false
        }
    }
}

/// One to-do, project or area in a list. Expands into `ToDoEditor` when open.
struct ItemRow: View {
    let item: Item
    let context: RowContext
    var listFocused: Bool
    /// Neighbours in the same section, so adjacent selected rows merge into one block.
    var previousID: UUID?
    var nextID: UUID?

    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model
    @State private var height: CGFloat = 30
    @State private var hovering = false

    private var isEditing: Bool { state.editingID == item.id }
    private var isSelected: Bool { state.selection.contains(item.id) }

    var body: some View {
        Group {
            if case .todo(let todo) = item, isEditing {
                ToDoEditor(todo: todo)
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                row
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .overlay(alignment: state.dropIndicator?.after == true ? .bottom : .top) {
            if state.dropIndicator?.id == item.id {
                DropLine()
            }
        }
        .onDrop(of: [.url], delegate: RowDropDelegate(state: state, id: item.id, group: context.group, height: { height }))
        .id(item.id)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 9) {
            leading
                .padding(.top, 1.5)
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                    .keyPopover(isPresented: state.popoverBinding(nil, anchor: item.id), arrowEdge: .bottom) {
                        if let request = state.popover { PickerPopover(request: request) }
                    }
                if context.showsSubtitle, let subtitle = context.lists.subtitle(for: item) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .background(selectionShape.fill(isSelected ? (listFocused ? Color.rowSelectionFocused : Color.rowSelection) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                state.open(item.id)
            } else {
                state.click(item.id)
            }
        }
        .onDrag {
            let ids = state.selection.contains(item.id) ? state.targets : [item.id]
            if !state.selection.contains(item.id) { state.select(item.id) }
            return DragPayload.provider(ids)
        } preview: {
            DragPreview(title: item.title.nonEmpty ?? "New To-Do", count: state.selection.contains(item.id) ? state.selection.count : 1)
        }
        .contextMenu { ItemContextMenu(item: item, ids: state.targets(including: item.id)) }
        .opacity(item.status == .open || context.list == .logbook || context.list == .trash ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: item.status)
    }

    private var selectionShape: UnevenRoundedRectangle {
        let joinedAbove = previousID.map { state.selection.contains($0) && state.editingID != $0 } ?? false
        let joinedBelow = nextID.map { state.selection.contains($0) && state.editingID != $0 } ?? false
        let top: CGFloat = joinedAbove ? 0 : 6
        let bottom: CGFloat = joinedBelow ? 0 : 6
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                      topTrailingRadius: top, style: .continuous)
    }

    @ViewBuilder
    private var leading: some View {
        switch item {
        case .todo(let todo):
            CheckBox(status: todo.status, tint: .secondary, size: 15) {
                state.toggleComplete([todo.id])
            }
        case .project(let project):
            let progress = context.lists.snapshot.progress(of: project.id)
            Button { state.toggleComplete([project.id]) } label: {
                ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 15,
                            completed: project.status == .completed)
            }
            .buttonStyle(.plain)
            .help(project.isOpen ? "Complete project" : "Reopen project")
        case .area:
            Image(systemName: "shippingbox.fill").foregroundStyle(Theme.area).frame(width: 15)
        case .tag:
            Image(systemName: "tag.fill").foregroundStyle(.secondary).frame(width: 15)
        case .heading:
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).frame(width: 15)
        }
    }

    private var titleLine: some View {
        HStack(spacing: 5) {
            switch item {
            case .todo(let todo): scheduleBadges(todo)
            case .project(let project): scheduleBadges(project)
            default: EmptyView()
            }
            Text(item.title.nonEmpty ?? placeholder)
                .font(.system(size: 13.5, weight: item.project != nil ? .semibold : .regular))
                .foregroundStyle(item.title.isEmpty || item.status != .open ? .secondary : .primary)
                .strikethrough(item.status == .canceled, color: .secondary)
                .lineLimit(1)
            indicators
            tags
        }
    }

    private var placeholder: String {
        switch item {
        case .project: "New Project"
        case .area: "New Area"
        default: "New To-Do"
        }
    }

    @ViewBuilder
    private func scheduleBadges<T: Schedulable>(_ item: T) -> some View {
        if item.isOpen && context.showsTodayStar && item.isScheduled(onOrBefore: context.today) {
            Image(systemName: item.isEvening ? "moon.fill" : "star.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(item.isEvening ? Theme.evening : Theme.today)
        } else if item.isOpen && context.showsWhenDate, let date = item.startDate, date > context.today {
            Text(date.shortLabel(today: context.today)).chipStyle()
        }
    }

    @ViewBuilder
    private var indicators: some View {
        if case .todo(let todo) = item {
            let checklist = context.lists.snapshot.checklistProgress(of: todo.id)
            HStack(spacing: 4) {
                if todo.reminder != nil { Image(systemName: "bell.fill") }
                if todo.repeatRule != nil || todo.repeatSeries != nil { Image(systemName: "repeat") }
                if !todo.notes.isEmpty { Image(systemName: "doc.text") }
                if checklist.total > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "checklist")
                        Text("\(checklist.done)/\(checklist.total)")
                    }
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var tags: some View {
        let tags = context.lists.snapshot.tags(of: item)
        if !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags.prefix(4)) { tag in TagPill(title: tag.title) }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        let deadline: Day? = item.todo?.deadline ?? item.project?.deadline
        HStack(spacing: 8) {
            if context.list == .logbook, let completed = item.todo?.completedAt ?? item.project?.completedAt {
                Text(completed.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if let deadline, item.status == .open {
                let due = deadline <= context.today
                HStack(spacing: 3) {
                    Image(systemName: "flag.fill").font(.system(size: 9.5))
                    Text(deadline.deadlineLabel(today: context.today))
                }
                .font(.system(size: 11, weight: due ? .semibold : .regular))
                .foregroundStyle(due ? Theme.deadline : .secondary)
            }
        }
        .padding(.top, 2)
    }
}

/// The blue insertion line shown while dragging rows.
struct DropLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 7, height: 7)
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .offset(y: -1)
        .allowsHitTesting(false)
    }
}

struct DragPreview: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square").font(.system(size: 12))
            Text(count > 1 ? "\(count) items" : title).lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.cardBackground))
        .shadow(radius: 2)
    }
}

/// Reordering by drag: drops above or below the row depending on where the pointer is.
struct RowDropDelegate: DropDelegate {
    let state: WindowState
    let id: UUID
    let group: ItemGroup?
    let height: () -> CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        group != nil && info.hasItemsConforming(to: [.url])
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if state.dropIndicator?.id == id { state.dropIndicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let group else { return false }
        let after = info.location.y > height() / 2
        let items = group.items.map(\.id)
        var target: UUID? = id
        if after, let index = items.firstIndex(of: id) {
            target = index + 1 < items.count ? items[index + 1] : nil
        }
        let state = state
        DragPayload.load(info.itemProviders(for: [.url])) { ids in
            // Skip past dragged items so "after" lands in the right place.
            var resolved = target
            while let current = resolved, ids.contains(current), let index = items.firstIndex(of: current) {
                resolved = index + 1 < items.count ? items[index + 1] : nil
            }
            state.drop(ids, before: resolved, in: group)
        }
        state.endDrop()
        return true
    }

    private func update(_ info: DropInfo) {
        guard group != nil, Date() > state.suppressDropIndicatorUntil else { return }
        let indicator = DropIndicator(id: id, after: info.location.y > height() / 2)
        if state.dropIndicator != indicator { state.dropIndicator = indicator }
    }
}

/// Right-click menu for rows.
struct ItemContextMenu: View {
    let item: Item
    let ids: [UUID]
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        if state.current == .trash {
            Button("Put Back") { state.restore(ids) }
            Button("Delete Immediately", role: .destructive) {
                for id in ids { store.delete(id) }
            }
        } else {
            switch item {
            case .area(let area):
                Button("Open") { state.navigate(to: .area(area.id)) }
            default:
                if item.project != nil {
                    Button("Open Project") { state.open(item.id) }
                    Divider()
                } else if ids.count == 1 {
                    Button("Open") { state.open(item.id) }
                    Divider()
                }
                Button(item.status == .completed ? "Mark as Open" : "Complete") { state.toggleComplete(ids) }
                Button(item.status == .canceled ? "Mark as Open" : "Cancel") { state.toggleCanceled(ids) }
                Divider()
                Menu("When") {
                    Button("Today") { state.schedule(.today, ids) }
                    Button("This Evening") { state.schedule(.evening, ids) }
                    Button("Tomorrow") { state.schedule(.date(model.today.adding(days: 1)), ids) }
                    Button("Anytime") { state.schedule(.anytime, ids) }
                    Button("Someday") { state.schedule(.someday, ids) }
                    Divider()
                    Button("Choose…") { state.showPicker(.when, ids) }
                }
                Button("Deadline…") { state.showPicker(.deadline, ids) }
                Button("Tags…") { state.showPicker(.tags, ids) }
                Button("Move…") { state.showPicker(.move, ids) }
                if item.todo != nil {
                    Button("Repeat…") { state.showPicker(.repeatRule, ids) }
                    Button("Reminder…") { state.showPicker(.reminder, ids) }
                    Divider()
                    Button("Duplicate") {
                        state.selection = Set(ids)
                        state.duplicate()
                    }
                    if ids.count == 1 {
                        Button("Convert to Project") {
                            state.select(item.id)
                            state.convertToProject()
                        }
                    }
                }
                Divider()
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("dabble:///show?id=\(item.id.uuidString)", forType: .string)
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { state.trash(ids) }
        }
    }
}
