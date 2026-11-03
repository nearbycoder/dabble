import DabbleKit
import SwiftUI

/// An open to-do, presented as a card: title, notes, checklist, tags and
/// its schedule, with Things' row of buttons along the bottom.
struct ToDoDetailView: View {
    let target: DetailTarget
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: ItemSheet?
    @State private var focusItem: UUID?
    @State private var confirmDelete = false

    private var store: DabbleStore { model.store }

    var body: some View {
        NavigationStack {
            Group {
                if let todo = store.todo(target.id) {
                    card(todo)
                } else {
                    ContentUnavailableView("To-Do Deleted", systemImage: "trash", description: Text("This to-do no longer exists."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let todo = store.todo(target.id) {
                        Text(location(of: todo))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.disabled)
        .itemSheet($sheet)
        .confirmationDialog("Delete this to-do?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                store.trash([target.id])
                dismiss()
            }
        }
    }

    private func card(_ todo: ToDo) -> some View {
        let snapshot = store.snapshot
        let checklist = snapshot.checklists[todo.id] ?? []
        let tags = snapshot.tags(of: .todo(todo))
        return List {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    CheckBox(status: todo.status, size: 22) { toggle(todo) }
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                    EditableText(placeholder: "New To-Do", value: todo.title, axis: .vertical, autoFocus: target.isNew) { title in
                        store.update(ToDo.self, todo.id) { $0.title = title.replacingOccurrences(of: "\n", with: " ") }
                    }
                    .font(.title3.weight(.semibold))
                    .submitLabel(.next)
                }
                .padding(.top, 4)
                EditableText(placeholder: "Notes", value: todo.notes, axis: .vertical) { notes in
                    store.update(ToDo.self, todo.id) { $0.notes = notes }
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(2...20)
                .padding(.leading, 34)
            }
            .listRowSeparator(.hidden)

            if !checklist.isEmpty {
                Section {
                    ForEach(checklist) { item in
                        ChecklistRow(item: item, autoFocus: focusItem == item.id) { title in
                            if title.trimmingCharacters(in: .whitespaces).isEmpty {
                                store.delete(item.id)
                            } else {
                                focusItem = store.addChecklistItem("", to: todo.id, after: item.id).id
                            }
                        }
                    }
                    .onMove { source, destination in
                        var ids = checklist.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        store.reorder(ids)
                    }
                    .onDelete { offsets in
                        for offset in offsets { store.delete(checklist[offset].id) }
                    }
                    .listRowSeparatorTint(Color.secondary.opacity(0.15))
                    .listRowInsets(EdgeInsets(top: 4, leading: 54, bottom: 4, trailing: 16))
                }
            }

            if !tags.isEmpty {
                Section {
                    Button { sheet = .tags([todo.id]) } label: {
                        FlowLayout(spacing: 6) {
                            ForEach(tags) { tag in
                                Text(tag.title)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Theme.tagBackground))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 54, bottom: 6, trailing: 16))
                }
                .listRowSeparator(.hidden)
            }

            Section {
                attributes(todo)
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .listSectionSpacing(4)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { actionBar(todo) }
    }

    // MARK: - Attributes

    @ViewBuilder
    private func attributes(_ todo: ToDo) -> some View {
        let today = model.today
        if let when = todo.whenDescription(today: today) {
            AttributeRow(systemImage: when.systemImage, tint: when.tint, title: when.title,
                         detail: todo.reminder.map { reminderLabel($0) }) {
                sheet = .when([todo.id])
            } clear: {
                store.schedule([todo.id], todo.projectID == nil && todo.areaID == nil ? .inbox : .anytime, today: today)
                store.setReminder(todo.id, minutes: nil, today: today)
            }
        }
        if let deadline = todo.deadline {
            AttributeRow(systemImage: "flag.fill", tint: deadline <= today ? Theme.deadline : .secondary,
                         title: "Deadline: \(deadline.relativeLabel(today: today))", detail: deadline.deadlineLabel(today: today)) {
                sheet = .deadline([todo.id])
            } clear: {
                store.setDeadline([todo.id], nil)
            }
        }
        if let rule = todo.repeatRule {
            AttributeRow(systemImage: "arrow.triangle.2.circlepath", tint: .secondary, title: rule.summary) {
                sheet = .repeatRule(todo.id)
            } clear: {
                store.setRepeat(todo.id, nil, today: today)
            }
        }
        if todo.reminder != nil && todo.startDate == nil {
            AttributeRow(systemImage: "bell.fill", tint: .secondary, title: reminderLabel(todo.reminder!)) {
                sheet = .reminder(todo.id)
            } clear: {
                store.setReminder(todo.id, minutes: nil, today: today)
            }
        }
    }

    // MARK: - Bottom bar

    private func actionBar(_ todo: ToDo) -> some View {
        HStack(spacing: 0) {
            barButton("calendar", label: "When") { sheet = .when([todo.id]) }
            barButton("tag", label: "Tags") { sheet = .tags([todo.id]) }
            barButton("checklist", label: "Checklist") {
                let last = store.snapshot.checklists[todo.id]?.last?.id
                focusItem = store.addChecklistItem("", to: todo.id, after: last).id
            }
            barButton("flag", label: "Deadline") { sheet = .deadline([todo.id]) }
            barButton("arrow.right.circle", label: "Move") { sheet = .move([todo.id]) }
            Menu {
                Button("Reminder", systemImage: "bell") { sheet = .reminder(todo.id) }
                Button("Repeat", systemImage: "arrow.triangle.2.circlepath") { sheet = .repeatRule(todo.id) }
                Divider()
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    if let copy = store.duplicateToDo(todo.id) { router.open(copy.id) }
                }
                Button("Convert to Project", systemImage: "circle.circle") {
                    if let project = store.convertToProject(todo.id) {
                        dismiss()
                        router.push(.project(project.id))
                    }
                }
                if todo.isOpen {
                    Button("Cancel To-Do", systemImage: "xmark.circle") {
                        store.setStatus([todo.id], .canceled, today: model.today)
                    }
                } else {
                    Button("Mark as Open", systemImage: "circle") {
                        store.setStatus([todo.id], .open, today: model.today)
                    }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func barButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggle(_ todo: ToDo) {
        let wasOpen = todo.isOpen
        withAnimation(.snappy) {
            store.setStatus([todo.id], wasOpen ? .completed : .open, today: model.today)
        }
        if wasOpen {
            router.didComplete()
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                dismiss()
            }
        }
    }

    private func location(of todo: ToDo) -> String {
        let snapshot = store.snapshot
        if let projectID = todo.projectID, let project = snapshot.projects[projectID] {
            if let headingID = todo.headingID, let heading = snapshot.headings[headingID] {
                return "\(project.title.nonEmpty ?? "New Project") › \(heading.title)"
            }
            return project.title.nonEmpty ?? "New Project"
        }
        if let areaID = todo.areaID, let area = snapshot.areas[areaID] { return area.title }
        if todo.start == .inbox { return "Inbox" }
        return todo.whenDescription(today: model.today)?.title ?? "Anytime"
    }
}

/// A tappable attribute with a clear button: "★ Today", "⚑ Deadline: Fri".
private struct AttributeRow: View {
    var systemImage: String
    var tint: Color
    var title: String
    var detail: String?
    var action: () -> Void
    var clear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .frame(width: 22)
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear")
        }
        .padding(.vertical, 4)
    }
}

/// One checklist line: a small circle and an editable title.
private struct ChecklistRow: View {
    let item: ChecklistItem
    var autoFocus: Bool
    var onSubmit: (String) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                withAnimation(.snappy) { model.store.toggleChecklistItem(item.id) }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary.opacity(0.6))
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as not done" : "Mark as done")
            EditableText(placeholder: "", value: item.title, autoFocus: autoFocus, onCommit: { title in
                model.store.update(ChecklistItem.self, item.id) { $0.title = title }
            }, onSubmit: onSubmit)
            .foregroundStyle(item.isDone ? .secondary : .primary)
            .submitLabel(.next)
        }
    }
}
