import AppKit
import Carbon.HIToolbox
import DabbleKit
import SwiftUI

/// Owns the Quick Entry panel and its global shortcut (⌃Space).
@MainActor
final class QuickEntryController {
    static let hotKeyDefaultsKey = "quickEntryHotKeyEnabled"
    private(set) static var shared: QuickEntryController?

    private let model: AppModel
    private var panel: QuickEntryPanel?
    private var hotKey: HotKey?
    private(set) var hotKeyRegistered = false

    init(model: AppModel) {
        self.model = model
        Self.shared = self
        updateHotKey()
    }

    static var hotKeyEnabled: Bool {
        UserDefaults.standard.object(forKey: hotKeyDefaultsKey) as? Bool ?? true
    }

    func updateHotKey() {
        hotKey = nil
        if Self.hotKeyEnabled {
            hotKey = HotKey(keyCode: kVK_Space, modifiers: controlKey) { [weak self] in self?.toggle() }
        }
        hotKeyRegistered = hotKey != nil
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        close()
        let panel = QuickEntryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 150),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.onCancel = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: QuickEntryView(
            onClose: { [weak self] in self?.close() },
            onHeightChange: { [weak panel] height in
                // Grow downward from a fixed top edge as notes get longer.
                guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
                let top = panel.frame.maxY
                panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height), display: true)
            }
        ).environment(model))
        panel.contentView = hosting

        // Upper third of the screen the pointer is on, like Things.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = hosting.fittingSize
            panel.setContentSize(size)
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 3 - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

final class QuickEntryPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// The Quick Entry form: title, notes and When/Tags/Deadline/List buttons.
struct QuickEntryView: View {
    var onClose: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var notes = ""
    @State private var when: When?
    @State private var reminder: Int?
    @State private var tags: [UUID] = []
    @State private var deadline: Day?
    @State private var destination: Destination = .inbox
    @State private var picker: PickerKind?
    @State private var focusToken = 1
    @State private var notesFocusToken: Int?

    var body: some View {
        let today = model.today
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.4)
                    .frame(width: 15, height: 15)
                PlainTextField(text: $title, placeholder: "New To-Do", font: .systemFont(ofSize: 16, weight: .medium), focusToken: focusToken) { command in
                    switch command {
                    case .submit: save()
                    case .escape: onClose()
                    case .down, .tab: notesFocusToken = (notesFocusToken ?? 0) + 1
                    default: return false
                    }
                    return true
                }
                .frame(height: 22)
            }
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Notes").font(.system(size: 13)).foregroundStyle(.tertiary).allowsHitTesting(false)
                }
                NotesTextView(text: $notes, font: .systemFont(ofSize: 13), focusToken: notesFocusToken) { command in
                    switch command {
                    case .escape: onClose()
                    case .backtab, .up: focusToken += 1
                    case .tab: break
                    default: return false
                    }
                    return true
                }
                .frame(minHeight: 34, alignment: .topLeading)
            }
            .padding(.leading, 25)

            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.compactMap { model.store.tag($0) }) { TagPill(title: $0.title) }
                }
                .padding(.leading, 25)
            }

            HStack(spacing: 6) {
                pickerButton(.move) {
                    Label(destinationTitle, systemImage: destinationIcon)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                if let when {
                    pickerButton(.when) {
                        Label(when.label + (reminder.map { " · \(reminderLabel($0))" } ?? ""), systemImage: when == .evening ? "moon.fill" : (when == .someday ? "archivebox.fill" : "star.fill"))
                            .chipStyle(when == .evening ? Theme.evening : (when == .someday ? Theme.someday : (when == .today ? Theme.today : .secondary)))
                    }
                }
                if let deadline {
                    pickerButton(.deadline) {
                        Label(deadline.shortLabel(today: today), systemImage: "flag.fill").chipStyle(Theme.deadline)
                    }
                }
                Spacer()
                if when == nil { pickerButton(.when) { icon("calendar", help: "When") } }
                pickerButton(.tags) { icon("tag", help: "Tags") }
                if deadline == nil { pickerButton(.deadline) { icon("flag", help: "Deadline") } }
            }
            .padding(.leading, 25)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.cardBackground)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .background {
            Button("Save", action: save)
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        }
        .onExitCommand { onClose() }
    }

    private var destinationTitle: String {
        switch destination {
        case .inbox, .none: "Inbox"
        case .area(let id): model.store.area(id)?.title.nonEmpty ?? "New Area"
        case .project(let id, let heading):
            (model.store.project(id)?.title.nonEmpty ?? "New Project") + (heading.flatMap { model.store.heading($0)?.title }.map { " › \($0)" } ?? "")
        }
    }

    private var destinationIcon: String {
        switch destination {
        case .inbox, .none: "tray.fill"
        case .area: "shippingbox.fill"
        case .project: "circle"
        }
    }

    private func icon(_ name: String, help: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
            .help(help)
    }

    private func pickerButton<Label: View>(_ kind: PickerKind, @ViewBuilder label: () -> Label) -> some View {
        Button { picker = kind } label: { label() }
            .buttonStyle(.plain)
            .keyPopover(isPresented: Binding(get: { picker == kind }, set: { if !$0 { picker = nil } }), arrowEdge: .bottom) {
                pickerContent(kind)
            }
    }

    @ViewBuilder
    private func pickerContent(_ kind: PickerKind) -> some View {
        switch kind {
        case .when:
            WhenPicker(current: when, reminder: reminder, onSelect: { value in
                when = value
                if value == nil { reminder = nil }
                picker = nil
            }, onReminder: { minutes in
                reminder = minutes
                if minutes != nil && when == nil { when = .today }
                picker = nil
            })
        case .deadline:
            DeadlinePicker(current: deadline) { day in
                deadline = day
                picker = nil
            }
        case .tags:
            TagPicker(selected: Set(tags)) { tag in
                if let index = tags.firstIndex(of: tag) { tags.remove(at: index) } else { tags.append(tag) }
            }
        case .move:
            MovePicker(movingProjects: false) { value in
                destination = value
                picker = nil
            }
        case .repeatRule, .reminder:
            EmptyView()
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onClose()
            return
        }
        let store = model.store
        let list: ListID
        var heading: UUID?
        switch destination {
        case .inbox, .none: list = .inbox
        case .area(let id): list = .area(id)
        case .project(let id, let h):
            list = .project(id)
            heading = h
        }
        store.batch {
            let todo = store.addToDo(trimmed, notes: notes, in: list, heading: heading, when: when, today: model.today)
            if !tags.isEmpty { store.setTags(todo.id, tags) }
            if let deadline { store.setDeadline([todo.id], deadline) }
            if let reminder { store.setReminder(todo.id, minutes: reminder, today: model.today) }
        }
        onClose()
    }
}
