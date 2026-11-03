import AppKit
import DabbleKit
import SwiftUI

/// Menu bar commands. They act on the key window's `WindowState`.
struct DabbleCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowState) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New To-Do") { state?.newToDo() }
                .keyboardShortcut("n")
                .disabled(!(state?.canAddToDo ?? false))
            Button("New Heading") { state?.newHeading() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!isProject)
            Button("New Project") { state?.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(state == nil)
            Button("New Area") { state?.newArea() }
                .disabled(state == nil)
            Divider()
            Button("New To-Do in Quick Entry") { QuickEntryController.shared?.show() }
                .keyboardShortcut(.space, modifiers: .control)
            Divider()
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .control])
        }

        CommandMenu("Items") {
            Button(allCompleted ? "Mark as Open" : "Complete") { state?.toggleComplete() }
                .keyboardShortcut("k")
                .disabled(!hasTargets)
            Button("Cancel") { state?.toggleCanceled() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!hasTargets)
            Divider()
            Button("When…") { state?.showPicker(.when) }
                .keyboardShortcut("s")
                .disabled(!hasTargets)
            Button("Today") { state?.schedule(.today) }
                .keyboardShortcut("t")
                .disabled(!hasTargets)
            Button("This Evening") { state?.schedule(.evening) }
                .keyboardShortcut("e")
                .disabled(!hasTargets)
            Button("Anytime") { state?.schedule(.anytime) }
                .keyboardShortcut("r")
                .disabled(!hasTargets)
            Button("Someday") { state?.schedule(.someday) }
                .keyboardShortcut("o")
                .disabled(!hasTargets)
            Divider()
            Button("Deadline…") { state?.showPicker(.deadline) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!hasTargets)
            Button("Tags…") { state?.showPicker(.tags) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!hasTargets)
            Button("Move…") { state?.showPicker(.move) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!hasTargets)
            Button("Add Checklist") { state?.addChecklist() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!(state?.targetsAreToDos ?? false))
            Button("Repeat…") { state?.showPicker(.repeatRule) }
                .disabled(!(state?.targetsAreToDos ?? false))
            Button("Reminder…") { state?.showPicker(.reminder) }
                .disabled(!hasTargets)
            Menu("Toggle Tag") {
                let tags = model.store.snapshot.tagList
                ForEach(tags) { tag in
                    if let key = tag.shortcut?.first {
                        Button(tag.title) { state?.toggleTag(tag.id) }
                            .keyboardShortcut(KeyEquivalent(key), modifiers: .control)
                            .disabled(!hasTargets || isEditing)
                    } else {
                        Button(tag.title) { state?.toggleTag(tag.id) }
                            .disabled(!hasTargets)
                    }
                }
                if tags.isEmpty { Text("No tags") }
            }
            Divider()
            Button("Duplicate") { state?.duplicate() }
                .keyboardShortcut("d")
                .disabled(!(state?.targetsAreToDos ?? false))
            Button("Convert to Project") { state?.convertToProject() }
                .disabled(!(state?.targetsAreToDos ?? false) || (state?.targets.count ?? 0) != 1)
            Button("Move Up") { state?.moveItems(up: true) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!hasTargets || isEditing)
            Button("Move Down") { state?.moveItems(up: false) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!hasTargets || isEditing)
            Divider()
            Button("Open") { if let id = state?.selection.first { state?.open(id) } }
                .disabled(state?.selection.count != 1 || isEditing)
            Button("Move to Trash") { state?.trash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasTargets || isEditing)
        }

        CommandMenu("List") {
            ForEach(Array(ListID.builtIn.enumerated()), id: \.offset) { index, list in
                Button(list.title(in: model.store)) { state?.navigate(to: list) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(state == nil)
            }
            Divider()
            Button("Quick Find") { state?.openQuickFind() }
                .keyboardShortcut("f")
                .disabled(state == nil)
            Divider()
            Button(state?.showLogged == true ? "Hide Logged Items" : "Show Logged Items") { state?.showLogged.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!isProjectOrArea)
            Button("Log Completed Now") { model.store.logCompleted() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Empty Trash") { model.store.emptyTrash() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
    }

    private var hasTargets: Bool { state?.hasTargets ?? false }
    private var isEditing: Bool { state?.editingID != nil }

    private var allCompleted: Bool {
        guard let state, state.hasTargets else { return false }
        return state.targets.allSatisfy { model.store.status(of: $0) == .completed }
    }

    private var isProject: Bool {
        if case .project? = state?.list { return true }
        return false
    }

    private var isProjectOrArea: Bool {
        switch state?.list {
        case .project?, .area?: true
        default: false
        }
    }
}

/// Lets views without `openWindow` in their environment open a new window.
enum NewWindowRequest {
    static var openWindow: OpenWindowAction?

    static func open(_ list: ListID) {
        openWindow?(id: "main", value: list)
    }
}
