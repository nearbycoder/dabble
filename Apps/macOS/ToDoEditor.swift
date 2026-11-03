import AppKit
import DabbleKit
import SwiftUI

/// The card a to-do expands into, like Things: title, notes, checklist, and a
/// bar of buttons for When, Tags, Deadline, Checklist, Repeat and Reminder.
struct ToDoEditor: View {
    let todo: ToDo
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var notes = ""
    @State private var focusField: Field?
    @State private var focusToken = 0

    enum Field: Hashable {
        case title, notes
        case checklist(UUID)
    }

    var body: some View {
        let snapshot = model.store.snapshot
        let checklist = snapshot.checklists[todo.id] ?? []
        let tags = snapshot.tags(of: .todo(todo))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 9) {
                CheckBox(status: todo.status, tint: .secondary, size: 15) { state.toggleComplete([todo.id]) }
                PlainTextField(text: $title, placeholder: "New To-Do", font: .systemFont(ofSize: 14, weight: .medium),
                               focusToken: token(for: .title)) { command in
                    switch command {
                    case .submit, .escape:
                        state.finishEditing()
                        return true
                    case .down, .tab:
                        focus(.notes)
                        return true
                    default:
                        return false
                    }
                }
                .frame(height: 20)
            }

            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Notes")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                NotesTextView(text: $notes, focusToken: token(for: .notes)) { command in
                    switch command {
                    case .escape:
                        state.finishEditing()
                        return true
                    case .up, .backtab:
                        focus(.title)
                        return true
                    case .down:
                        if let first = checklist.first {
                            focus(.checklist(first.id))
                            return true
                        }
                        return false
                    case .tab:
                        if let first = checklist.first { focus(.checklist(first.id)) }
                        return true
                    default:
                        return false
                    }
                }
            }
            .padding(.leading, 24)

            if !checklist.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(checklist) { item in
                        ChecklistRow(item: item, focusToken: token(for: .checklist(item.id))) { command in
                            handle(command, on: item, in: checklist)
                        }
                        Divider().opacity(0.5)
                    }
                }
                .padding(.leading, 24)
            }

            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags) { tag in
                        TagPill(title: tag.title)
                    }
                }
                .padding(.leading, 24)
                .onTapGesture { state.showPicker(.tags, [todo.id]) }
            }

            bottomBar(hasChecklist: !checklist.isEmpty)
                .padding(.leading, 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
        .contentShape(Rectangle())
        .onTapGesture {}
        .onAppear {
            title = todo.title
            notes = todo.notes
            focus(.title)
        }
        .onChange(of: state.editorFocusRequest) { focus(.title) }
        .onChange(of: state.checklistRequest) {
            let items = model.store.snapshot.checklists[todo.id] ?? []
            let item = model.store.addChecklistItem("", to: todo.id, after: items.last?.id)
            focus(.checklist(item.id))
        }
        .onChange(of: title) { _, value in
            if value != model.store.todo(todo.id)?.title {
                model.store.write(todo.id, kind: .todo, [Key.title: .string(value)], undoable: false)
            }
        }
        .onChange(of: notes) { _, value in
            if value != model.store.todo(todo.id)?.notes {
                model.store.write(todo.id, kind: .todo, [Key.notes: .string(value)], undoable: false)
            }
        }
        .onChange(of: todo.title) { _, value in if value != title { title = value } }
        .onChange(of: todo.notes) { _, value in if value != notes { notes = value } }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private func bottomBar(hasChecklist: Bool) -> some View {
        let today = model.today
        HStack(spacing: 6) {
            if let when = When(of: todo, today: today) {
                EditorPickerButton(kind: .when, id: todo.id) {
                    chip(icon: whenIcon(when), tint: whenTint(when), text: whenLabel(when, today: today)) {
                        state.schedule(.anytime, [todo.id])
                    }
                }
            }
            if let deadline = todo.deadline {
                EditorPickerButton(kind: .deadline, id: todo.id) {
                    chip(icon: "flag.fill", tint: deadline <= today ? Theme.deadline : .secondary,
                         text: "Deadline: \(deadline.shortLabel(today: today))") {
                        model.store.setDeadline([todo.id], nil)
                    }
                }
            }
            if let reminder = todo.reminder {
                EditorPickerButton(kind: .reminder, id: todo.id) {
                    chip(icon: "bell.fill", tint: .secondary, text: reminderLabel(reminder)) {
                        model.store.setReminder(todo.id, minutes: nil)
                    }
                }
            }
            if let rule = todo.repeatRule {
                EditorPickerButton(kind: .repeatRule, id: todo.id) {
                    chip(icon: "repeat", tint: .secondary, text: rule.summary) {
                        model.store.setRepeat(todo.id, nil)
                    }
                }
            }
            Spacer(minLength: 8)
            if When(of: todo, today: today) == nil {
                EditorPickerButton(kind: .when, id: todo.id) { barIcon("calendar", help: "When (⌘S)") }
            }
            EditorPickerButton(kind: .tags, id: todo.id) { barIcon("tag", help: "Tags (⇧⌘T)") }
            if !hasChecklist {
                Button { addFirstChecklistItem() } label: { barIcon("checklist", help: "Checklist") }
                    .buttonStyle(.plain)
            }
            if todo.deadline == nil {
                EditorPickerButton(kind: .deadline, id: todo.id) { barIcon("flag", help: "Deadline (⇧⌘D)") }
            }
            if todo.repeatRule == nil {
                EditorPickerButton(kind: .repeatRule, id: todo.id) { barIcon("repeat", help: "Repeat") }
            }
            if todo.reminder == nil {
                EditorPickerButton(kind: .reminder, id: todo.id) { barIcon("bell", help: "Reminder") }
            }
        }
    }

    private func chip(icon: String, tint: Color, text: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).foregroundStyle(.primary)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func barIcon(_ name: String, help: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
            .help(help)
    }

    private func whenIcon(_ when: When) -> String {
        switch when {
        case .today: "star.fill"
        case .evening: "moon.fill"
        case .someday: "archivebox.fill"
        default: "calendar"
        }
    }

    private func whenTint(_ when: When) -> Color {
        switch when {
        case .today: Theme.today
        case .evening: Theme.evening
        case .someday: Theme.someday
        default: Theme.upcoming
        }
    }

    private func whenLabel(_ when: When, today: Day) -> String {
        if case .date(let day) = when { return day.shortLabel(today: today) }
        return when.label
    }

    // MARK: Focus & checklist

    private func token(for field: Field) -> Int? {
        focusField == field ? focusToken : nil
    }

    private func focus(_ field: Field) {
        focusField = field
        focusToken += 1
    }

    private func addFirstChecklistItem() {
        let item = model.store.addChecklistItem("", to: todo.id)
        focus(.checklist(item.id))
    }

    private func handle(_ command: FieldCommand, on item: ChecklistItem, in items: [ChecklistItem]) -> Bool {
        let index = items.firstIndex { $0.id == item.id } ?? 0
        switch command {
        case .submit:
            let new = model.store.addChecklistItem("", to: todo.id, after: item.id)
            focus(.checklist(new.id))
            return true
        case .deleteWhenEmpty:
            model.store.delete(item.id)
            focus(index > 0 ? .checklist(items[index - 1].id) : .notes)
            return true
        case .up:
            focus(index > 0 ? .checklist(items[index - 1].id) : .notes)
            return true
        case .down:
            if index + 1 < items.count { focus(.checklist(items[index + 1].id)) }
            return true
        case .escape:
            state.finishEditing()
            return true
        case .tab, .backtab:
            return false
        }
    }
}

/// A bottom-bar button that opens its picker as a popover anchored to itself.
struct EditorPickerButton<Label: View>: View {
    let kind: PickerKind
    let id: UUID
    @ViewBuilder var label: () -> Label
    @Environment(WindowState.self) private var state

    var body: some View {
        Button { state.showPicker(kind, [id]) } label: { label() }
            .buttonStyle(.plain)
            .keyPopover(isPresented: state.popoverBinding(kind, anchor: id), arrowEdge: .bottom) {
                if let request = state.popover { PickerPopover(request: request) }
            }
    }
}

/// One checklist line: a small circle and an editable title. Drag to reorder.
struct ChecklistRow: View {
    let item: ChecklistItem
    var focusToken: Int?
    var onCommand: (FieldCommand) -> Bool
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 8) {
            Button { model.store.toggleChecklistItem(item.id) } label: {
                ZStack {
                    Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.2)
                    if item.isDone {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "checkmark").font(.system(size: 6.5, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 11, height: 11)
                .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            PlainTextField(text: $text, placeholder: "", font: .systemFont(ofSize: 12.5),
                           textColor: item.isDone ? .secondaryLabelColor : .labelColor,
                           focusToken: focusToken, onCommand: onCommand)
                .frame(height: 22)
        }
        .padding(.vertical, 1)
        .overlay(alignment: .top) { if dropTarget { DropLine() } }
        .onAppear { text = item.title }
        .onChange(of: item.title) { _, value in if value != text { text = value } }
        .onChange(of: text) { _, value in
            if value != item.title { model.store.write(item.id, kind: .checklist, [Key.title: .string(value)], undoable: false) }
        }
        .onDrag { NSItemProvider(object: "dabble-checklist:\(item.id.uuidString)" as NSString) }
        .dropDestination(for: String.self) { values, _ in
            guard let raw = values.first, raw.hasPrefix("dabble-checklist:"),
                  let dragged = UUID(uuidString: String(raw.dropFirst("dabble-checklist:".count))),
                  let todoID = item.todoID, dragged != item.id else { return false }
            var order = (model.store.snapshot.checklists[todoID] ?? []).map(\.id).filter { $0 != dragged }
            order.insert(dragged, at: order.firstIndex(of: item.id) ?? order.count)
            withAnimation(.snappy) { model.store.reorder(order) }
            return true
        } isTargeted: { dropTarget = $0 }
    }
}
