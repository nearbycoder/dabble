import AppKit
import DabbleKit
import SwiftUI

/// Big icon + title at the top of a list. Projects and areas get an editable
/// title, notes, When/Deadline chips and a "…" menu.
struct ListHeader: View {
    let list: ListID
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                icon
                switch list {
                case .project(let id):
                    EditableTitle(id: id, kind: .project, placeholder: "New Project")
                    ProjectMenu(projectID: id)
                case .area(let id):
                    EditableTitle(id: id, kind: .area, placeholder: "New Area")
                    AreaMenu(areaID: id)
                default:
                    Text(list.title(in: model.store))
                        .font(.system(size: 26, weight: .bold))
                }
                Spacer()
                if list == .trash, !(model.lists.trash().first?.items.isEmpty ?? true) {
                    Button("Empty Trash") { model.store.emptyTrash() }
                        .controlSize(.regular)
                }
            }
            if case .project(let id) = list, let project = model.store.project(id) {
                ProjectDetails(project: project)
            }
            if case .area(let id) = list, let area = model.store.area(id) {
                let tags = model.store.snapshot.tags(of: .area(area))
                if !tags.isEmpty {
                    HStack(spacing: 4) { ForEach(tags) { TagPill(title: $0.title) } }
                        .padding(.leading, 40)
                }
            }
        }
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var icon: some View {
        switch list {
        case .project(let id):
            let progress = model.store.snapshot.progress(of: id)
            ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 24,
                        completed: model.store.project(id)?.status == .completed)
                .frame(width: 30)
        default:
            Image(systemName: list.systemImage)
                .font(.system(size: 23))
                .foregroundStyle(list.tint)
                .frame(width: 30)
        }
    }
}

/// Inline-editable project or area title.
struct EditableTitle: View {
    let id: UUID
    let kind: Kind
    let placeholder: String
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var focusToken: Int?

    private var stored: String {
        kind == .project ? model.store.project(id)?.title ?? "" : model.store.area(id)?.title ?? ""
    }

    var body: some View {
        // The hidden text sizes the field to its content so the "…" menu sits right after it.
        Text((title.isEmpty ? placeholder : title) + "  ")
            .font(.system(size: 26, weight: .bold))
            .lineLimit(1)
            .hidden()
            .frame(minWidth: 140, alignment: .leading)
            .overlay {
                PlainTextField(text: $title, placeholder: placeholder, font: .systemFont(ofSize: 26, weight: .bold),
                               focusToken: focusToken) { command in
                    switch command {
                    case .submit, .escape, .down, .tab:
                        state.listFocusRequest += 1
                        return true
                    default:
                        return false
                    }
                }
            }
            .onAppear(perform: load)
            .onChange(of: id) { load() }
            .onChange(of: stored) { _, value in if value != title { title = value } }
            .onChange(of: title) { _, value in
                if value != stored { model.store.write(id, kind: kind, [Key.title: .string(value)], undoable: false) }
            }
            .onChange(of: state.focusHeaderTitle) { _, value in
                if value { focus() }
            }
    }

    private func load() {
        title = stored
        if state.focusHeaderTitle { focus() }
    }

    private func focus() {
        focusToken = (focusToken ?? 0) + 1
        state.focusHeaderTitle = false
    }
}

/// Notes, When/Deadline chips and tags under a project's title.
struct ProjectDetails: View {
    let project: Project
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model
    @State private var notes = ""

    var body: some View {
        let today = model.today
        let tags = model.store.snapshot.tags(of: .project(project))
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Notes").font(.system(size: 13)).foregroundStyle(.tertiary).allowsHitTesting(false)
                }
                NotesTextView(text: $notes, font: .systemFont(ofSize: 13)) { command in
                    if command == .escape {
                        state.listFocusRequest += 1
                        return true
                    }
                    return false
                }
            }
            let when = When(of: project, today: today)
            if when != nil || project.deadline != nil || !tags.isEmpty || project.status != .open {
                HStack(spacing: 6) {
                    if project.status != .open {
                        Label(project.status == .completed ? "Completed" : "Canceled",
                              systemImage: project.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .chipStyle(project.status == .completed ? Color.accentColor : .secondary)
                    }
                    if let when {
                        Button { state.showPicker(.when, [project.id]) } label: {
                            Label(when == .someday ? "Someday" : (when == .today || when == .evening ? when.label : "Starts \(whenLabel(when, today))"),
                                  systemImage: when == .someday ? "archivebox.fill" : (when == .today ? "star.fill" : "calendar"))
                                .chipStyle()
                        }
                        .buttonStyle(.plain)
                    }
                    if let deadline = project.deadline {
                        Button { state.showPicker(.deadline, [project.id]) } label: {
                            Label("Deadline \(deadline.shortLabel(today: today)) · \(deadline.deadlineLabel(today: today))", systemImage: "flag.fill")
                                .chipStyle(deadline <= today ? Theme.deadline : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(tags) { TagPill(title: $0.title) }
                }
            }
        }
        .padding(.leading, 40)
        .onAppear { notes = project.notes }
        .onChange(of: project.id) { notes = project.notes }
        .onChange(of: project.notes) { _, value in if value != notes { notes = value } }
        .onChange(of: notes) { _, value in
            if value != project.notes { model.store.write(project.id, kind: .project, [Key.notes: .string(value)], undoable: false) }
        }
    }

    private func whenLabel(_ when: When, _ today: Day) -> String {
        if case .date(let day) = when { return day.shortLabel(today: today) }
        return when.label
    }
}

/// The "…" menu next to a project's title.
struct ProjectMenu: View {
    let projectID: UUID
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model

    var body: some View {
        let project = model.store.project(projectID)
        Menu {
            Button(project?.status == .completed ? "Mark as Open" : "Complete Project") { state.toggleComplete([projectID]) }
            Button(project?.status == .canceled ? "Mark as Open" : "Cancel Project") { state.toggleCanceled([projectID]) }
            Divider()
            Button("When…") { state.showPicker(.when, [projectID]) }
            Button("Deadline…") { state.showPicker(.deadline, [projectID]) }
            Button("Tags…") { state.showPicker(.tags, [projectID]) }
            Button("Move…") { state.showPicker(.move, [projectID]) }
            Divider()
            Button("Add Heading") { state.newHeading() }
            Button("Show Logged Items") { state.showLogged = true }
                .disabled(state.showLogged)
            Divider()
            Button("Delete Project", role: .destructive) {
                model.store.trash([projectID])
                state.navigate(to: .today)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .keyPopover(isPresented: state.popoverBinding(nil, anchor: projectID), arrowEdge: .bottom) {
            if let request = state.popover { PickerPopover(request: request) }
        }
    }
}

struct AreaMenu: View {
    let areaID: UUID
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("New Project in Area") { state.newProject() }
            Button("New To-Do") { state.newToDo() }
            Button("Tags…") { state.showPicker(.tags, [areaID]) }
            Divider()
            Button("Delete Area", role: .destructive) {
                model.store.trash([areaID])
                state.navigate(to: .today)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .keyPopover(isPresented: state.popoverBinding(nil, anchor: areaID), arrowEdge: .bottom) {
            if let request = state.popover { PickerPopover(request: request) }
        }
    }
}
