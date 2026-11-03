import AppKit
import DabbleKit
import SwiftUI

/// The detail column: header, tag filter, sections of rows, logged items.
struct ListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @FocusState private var listFocused: Bool

    var body: some View {
        let lists = model.lists
        let list = state.current
        let allGroups = lists.items(for: list)
        let groups = lists.filter(allGroups, tag: state.tagFilter)
        let logged = state.loggedItems(in: lists)
        let missing = isMissing(list)
        let isEmpty = groups.allSatisfy { group in
            if case .heading = group.header { return false }
            return group.items.isEmpty
        }
        let signature = groups.map { $0.id + $0.items.map(\.id.uuidString).joined() }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if missing {
                        EmptyListView(list: .trash, message: "This list was deleted.")
                    } else {
                        ListHeader(list: list)
                        TagFilterBar(tags: lists.tagsUsed(in: allGroups))
                        if isEmpty && logged.isEmpty {
                            EmptyListView(list: list, message: list.emptyMessage)
                        }
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            GroupHeaderView(group: group, list: list, isFirst: index == 0)
                            let ids = group.items.map(\.id)
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                ItemRow(item: item, context: RowContext(list: list, group: group, lists: lists), listFocused: listFocused,
                                        previousID: index > 0 ? ids[index - 1] : nil,
                                        nextID: index + 1 < ids.count ? ids[index + 1] : nil)
                            }
                        }
                        LoggedSection(list: list, logged: logged, lists: lists, listFocused: listFocused)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 30)
                .padding(.bottom, 60)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .animation(.snappy(duration: 0.25), value: signature)
                .animation(.snappy(duration: 0.22), value: state.editingID)
            }
            .onChange(of: state.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) }
                state.scrollTarget = nil
            }
        }
        .background(Color.listBackground)
        .contentShape(Rectangle())
        .onTapGesture { state.clearSelection() }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onCommand(#selector(NSResponder.selectAll(_:))) { state.selectAll() }
        .onChange(of: state.listFocusRequest) { listFocused = true }
        .onAppear { listFocused = true }
        .safeAreaInset(edge: .bottom, spacing: 0) { ListBottomBar() }
    }

    private func isMissing(_ list: ListID) -> Bool {
        switch list {
        case .project(let id): model.store.project(id) == nil
        case .area(let id): model.store.area(id) == nil
        case .tag(let id): model.store.tag(id) == nil
        default: false
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // SwiftUI also routes keys typed into child panels (pickers) here.
        guard state.quickFindQuery == nil, state.popover == nil,
              let window = state.window, NSApp.keyWindow === window else { return .ignored }
        // …and keys typed into text fields nested in the list (titles, headings, notes).
        if window.firstResponder is NSText { return .ignored }
        if state.editingID != nil {
            if press.key == .escape {
                state.finishEditing()
                return .handled
            }
            return .ignored
        }
        let modifiers = press.modifiers
        switch press.key {
        case .upArrow, .downArrow:
            let up = press.key == .upArrow
            if modifiers.contains(.command) && modifiers.contains(.option) {
                state.moveItems(up: up)
            } else {
                state.moveCursor(by: up ? -1 : 1, extend: modifiers.contains(.shift))
            }
            return .handled
        case .return:
            if state.selection.count == 1, let id = state.selection.first {
                state.open(id)
                return .handled
            }
            return .ignored
        case .space:
            state.newToDo()
            return .handled
        case .delete, .deleteForward:
            guard !state.selection.isEmpty else { return .ignored }
            state.trash()
            return .handled
        case .escape:
            state.clearSelection()
            return .handled
        default:
            break
        }
        if modifiers == .control {
            return state.toggleTag(shortcut: String(press.key.character)) ? .handled : .ignored
        }
        if modifiers.subtracting(.shift).isEmpty, let character = press.characters.first,
           character.isLetter || character.isNumber {
            state.openQuickFind(press.characters)
            return .handled
        }
        return .ignored
    }
}

// MARK: - Sections

struct GroupHeaderView: View {
    let group: ItemGroup
    let list: ListID
    let isFirst: Bool
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        content
            .overlay(alignment: .bottom) { if targeted { DropLine() } }
            .onDrop(of: [.url], isTargeted: $targeted) { providers in
                let group = group
                DragPayload.load(providers) { ids in
                    state.drop(ids, before: group.items.first?.id, in: group)
                }
                return true
            }
    }

    @ViewBuilder
    private var content: some View {
        let today = model.today
        switch group.header {
        case .none:
            Color.clear.frame(height: isFirst || group.items.isEmpty ? 0 : 20)
        case .evening:
            sectionTitle {
                Label {
                    Text("This Evening")
                } icon: {
                    Image(systemName: "moon.fill").foregroundStyle(Theme.evening)
                }
            }
        case .heading(let heading):
            HeadingHeader(heading: heading)
                .padding(.top, 26)
                .padding(.bottom, 4)
        case .day(let day) where list == .upcoming:
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Color.hairline).frame(height: 1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(day.day)")
                        .font(.system(size: 24, weight: .bold))
                    Text(upcomingLabel(day, today: today))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, isFirst ? 4 : 22)
            .padding(.bottom, 4)
        case .day(let day):
            sectionTitle { Text(logbookLabel(day, today: today)) }
        case .month(let year, let month):
            sectionTitle {
                Text(Day(year: year, month: month, day: 1).date().formatted(.dateTime.month(.wide).year()))
            }
        case .area(let area):
            Button { state.navigate(to: .area(area.id)) } label: {
                sectionTitle {
                    Label {
                        Text(area.title.nonEmpty ?? "New Area")
                    } icon: {
                        Image(systemName: "shippingbox.fill").foregroundStyle(Theme.area)
                    }
                }
            }
            .buttonStyle(.plain)
        case .project(let project):
            Button { state.navigate(to: .project(project.id)) } label: {
                sectionTitle {
                    HStack(spacing: 7) {
                        let progress = model.store.snapshot.progress(of: project.id)
                        ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 14)
                        Text(project.title.nonEmpty ?? "New Project")
                    }
                }
            }
            .buttonStyle(.plain)
        case .later:
            sectionTitle {
                Label {
                    Text("Later")
                } icon: {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.someday)
                }
            }
        case .completed:
            sectionTitle { Text("Completed") }
        }
    }

    private func sectionTitle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            content()
                .font(.system(size: 13.5, weight: .bold))
                .contentShape(Rectangle())
            Rectangle().fill(Color.hairline).frame(height: 1)
        }
        .padding(.top, isFirst ? 4 : 26)
        .padding(.bottom, 4)
    }

    private func upcomingLabel(_ day: Day, today: Day) -> String {
        let offset = today.days(until: day)
        if offset == 1 { return "Tomorrow" }
        if offset < 7 { return day.date().formatted(.dateTime.weekday(.wide)) }
        if day.year == today.year { return day.date().formatted(.dateTime.weekday(.wide).month(.abbreviated)) }
        return day.date().formatted(.dateTime.weekday(.wide).month(.abbreviated).year())
    }

    private func logbookLabel(_ day: Day, today: Day) -> String {
        let offset = day.days(until: today)
        if offset == 0 { return "Today" }
        if offset == 1 { return "Yesterday" }
        if offset < 7 { return day.date().formatted(.dateTime.weekday(.wide)) }
        if day.year == today.year { return day.date().formatted(.dateTime.month(.wide).day()) }
        return day.date().formatted(.dateTime.month(.wide).day().year())
    }
}

/// An editable heading inside a project, with its own menu.
struct HeadingHeader: View {
    let heading: Heading
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var hovering = false
    @State private var focusToken: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                PlainTextField(text: $title, placeholder: "New Heading", font: .systemFont(ofSize: 13.5, weight: .bold),
                               textColor: NSColor(named: "AccentColor") ?? .controlAccentColor, focusToken: focusToken) { command in
                    switch command {
                    case .submit, .tab:
                        state.selection = []
                        state.pendingHeading = heading.id
                        state.listFocusRequest += 1
                        return true
                    case .escape:
                        state.listFocusRequest += 1
                        return true
                    default:
                        return false
                    }
                }
                .frame(height: 19)
                Menu {
                    Button("New To-Do in Heading") { state.newToDo(in: heading) }
                    Button("Archive Heading") {
                        withAnimation(.snappy) { model.store.update(Heading.self, heading.id) { $0.isArchived = true } }
                    }
                    Button("Convert to Project") {
                        if let project = model.store.convertHeadingToProject(heading.id) { state.navigate(to: .project(project.id)) }
                    }
                    Divider()
                    Button("Delete Heading", role: .destructive) {
                        withAnimation(.snappy) { model.store.trash([heading.id]) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
            }
            Rectangle().fill(Color.hairline).frame(height: 1)
        }
        .onHover { hovering = $0 }
        .id(heading.id)
        .onAppear {
            title = heading.title
            if state.focusHeadingID == heading.id { focus() }
        }
        .onChange(of: state.focusHeadingID) { _, id in
            if id == heading.id { focus() }
        }
        .onChange(of: heading.title) { _, value in if value != title { title = value } }
        .onChange(of: title) { _, value in
            if value != heading.title { model.store.write(heading.id, kind: .heading, [Key.title: .string(value)], undoable: false) }
        }
    }

    private func focus() {
        focusToken = (focusToken ?? 0) + 1
        state.focusHeadingID = nil
    }
}

/// Things' "Show 12 logged items" at the bottom of a project or area.
struct LoggedSection: View {
    let list: ListID
    let logged: [ToDo]
    let lists: Lists
    let listFocused: Bool
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model

    var body: some View {
        if !logged.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy) { state.showLogged.toggle() }
                } label: {
                    Text(state.showLogged ? "Hide logged items" : "Show \(logged.count) logged item\(logged.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Color.hairline))
                }
                .buttonStyle(.plain)
                .padding(.top, 28)
                .padding(.bottom, 8)
                if state.showLogged {
                    ForEach(logged) { todo in
                        ItemRow(item: .todo(todo), context: RowContext(list: .logbook, group: nil, lists: lists), listFocused: listFocused)
                    }
                }
            }
        }
    }
}

struct EmptyListView: View {
    let list: ListID
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: list.systemImage)
                .font(.system(size: 52))
                .foregroundStyle(list.tint.opacity(0.22))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

/// Tag chips to filter the current list, shown when its items carry tags.
struct TagFilterBar: View {
    let tags: [Tag]
    @Environment(WindowState.self) private var state

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    chip("All", selected: state.tagFilter == nil) { state.tagFilter = nil }
                    ForEach(tags) { tag in
                        chip(tag.title, selected: state.tagFilter == tag.id) {
                            state.tagFilter = state.tagFilter == tag.id ? nil : tag.id
                        }
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor : Theme.tagBackground))
                .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// The small toolbar at the bottom of the list, like Things'.
struct ListBottomBar: View {
    @Environment(WindowState.self) private var state

    var body: some View {
        HStack(spacing: 2) {
            button("plus", help: "New To-Do (⌘N)", disabled: !state.canAddToDo) { state.newToDo() }
            if case .project = state.current {
                button("text.badge.plus", help: "New Heading (⇧⌘N)") { state.newHeading() }
            }
            Spacer()
            button("calendar", help: "When (⌘S)", disabled: !state.hasTargets) { state.showPicker(.when) }
            button("arrow.right", help: "Move (⇧⌘M)", disabled: !state.hasTargets) { state.showPicker(.move) }
            button("magnifyingglass", help: "Quick Find (⌘F)") { state.openQuickFind() }
            Spacer()
            Color.clear.frame(width: 30)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.listBackground)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }

    private func button(_ icon: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(help)
    }
}
