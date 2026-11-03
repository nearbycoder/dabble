import DabbleKit
import SwiftUI

/// A row in the flattened list: either a section heading or an item.
/// Headings are rows (not `Section`s) so to-dos can be dragged across them.
struct FlatRow: Identifiable {
    enum Kind {
        case header(GroupHeader)
        case item(Item)
    }

    let id: String
    let kind: Kind
    let group: Int

    var item: Item? {
        if case .item(let item) = kind { return item }
        return nil
    }

    static func make(_ groups: [ItemGroup], list: ListID) -> [FlatRow] {
        var rows: [FlatRow] = []
        for (index, group) in groups.enumerated() {
            let showHeader: Bool
            switch group.header {
            case .none: showHeader = index > 0 && !group.items.isEmpty && rows.contains { $0.item != nil }
            case .heading: showHeader = true
            default: showHeader = !group.items.isEmpty
            }
            if showHeader {
                rows.append(FlatRow(id: "h-\(index)-\(group.id)", kind: .header(group.header), group: index))
            }
            for item in group.items {
                rows.append(FlatRow(id: item.id.uuidString, kind: .item(item), group: index))
            }
        }
        return rows
    }
}

struct ListScreen: View {
    let list: ListID
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var tagFilter: UUID?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var sheet: ItemSheet?
    @State private var showLogged = false
    @State private var showNavTitle = false
    @State private var headingPrompt: HeadingPrompt?
    @State private var headingTitle = ""
    @State private var confirmEmptyTrash = false
    @State private var confirmDeleteList = false

    private var store: DabbleStore { model.store }
    private var isEditing: Bool { editMode.isEditing }

    struct HeadingPrompt {
        var heading: Heading?
    }

    var body: some View {
        let lists = model.lists
        let allGroups = lists.items(for: list)
        let tags = list == .trash ? [] : lists.tagsUsed(in: allGroups)
        let groups = lists.filter(allGroups, tag: tagFilter)
        let rows = FlatRow.make(groups, list: list)
        let logged = (list.projectID != nil || list.areaID != nil) ? lists.loggedItems(in: list) : []
        let isEmpty = !rows.contains { $0.item != nil } && !rows.contains { if case .header(.heading) = $0.kind { true } else { false } }
        let exists = listEntityExists

        List(selection: $selection) {
            ListTitleHeader(list: list, lists: lists, present: { sheet = $0 })
                .listRowSeparator(.hidden)
                .selectionDisabled()
                .moveDisabled(true)

            if !tags.isEmpty {
                TagFilterBar(tags: tags, selection: $tagFilter)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .selectionDisabled()
            }

            ForEach(rows) { row in
                rowView(row, lists: lists)
            }
            .onMove(perform: list.supportsReordering && tagFilter == nil ? { move($0, to: $1, rows: rows, groups: groups) } : nil)

            if isEmpty && exists {
                EmptyListView(list: list, filtered: tagFilter != nil)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }

            if !logged.isEmpty {
                loggedSection(logged, lists: lists)
            }

            Color.clear
                .frame(height: 90)
                .listRowSeparator(.hidden)
                .selectionDisabled()
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .animation(.snappy, value: rows.map(\.id))
        .navigationTitle(showNavTitle ? list.title(in: store) : "")
        .navigationBarTitleDisplayMode(.inline)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 56
        } action: { _, scrolled in
            withAnimation(.easeInOut(duration: 0.15)) { showNavTitle = scrolled }
        }
        .refreshable {
            model.sync.syncNow()
            try? await Task.sleep(for: .milliseconds(700))
        }
        .overlay(alignment: .bottomTrailing) {
            if list.acceptsNewItems && !isEditing {
                plusButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .toolbar { toolbar(rows: rows) }
        .toolbar(isEditing ? .visible : .hidden, for: .bottomBar)
        .itemSheet($sheet, onDismiss: {
            if isEditing {
                selection = []
                withAnimation { editMode = .inactive }
            }
        })
        .alert(headingPrompt?.heading == nil ? "New Heading" : "Rename Heading", isPresented: Binding(
            get: { headingPrompt != nil },
            set: { if !$0 { headingPrompt = nil } }
        )) {
            TextField("Heading", text: $headingTitle)
            Button("Cancel", role: .cancel) { headingPrompt = nil }
            Button(headingPrompt?.heading == nil ? "Add" : "Save") { saveHeading() }
        }
        .confirmationDialog("Permanently delete everything in the Trash?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { store.emptyTrash() }
        } message: {
            Text("This can't be undone and removes the items from all your synced devices.")
        }
        .confirmationDialog(deleteListTitle, isPresented: $confirmDeleteList, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trashList() }
        }
        .onChange(of: listEntityExists) { _, exists in
            if !exists { router.leave(list) }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: FlatRow, lists: Lists) -> some View {
        switch row.kind {
        case .header(let header):
            GroupHeaderRow(header: header, list: list, lists: lists) { heading in
                headingTitle = heading.title
                headingPrompt = HeadingPrompt(heading: heading)
            }
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .selectionDisabled()
        case .item(let item):
            itemRow(item, lists: lists)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: Item, lists: Lists) -> some View {
        Group {
            switch item {
            case .todo(let todo):
                ToDoRow(todo: todo, list: list, lists: lists, isEditing: isEditing)
            case .project(let project):
                ProjectRow(project: project, list: list, lists: lists)
            case .area(let area):
                AreaRow(area: area)
            default:
                EmptyView()
            }
        }
        .modifier(TapToOpen(enabled: !isEditing) { open(item) })
        .listRowSeparator(.hidden)
        .tag(item.id)
        .contextMenu { ItemMenu(item: item, list: list, present: { sheet = $0 }) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if list == .trash {
                Button { store.restore([item.id]) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .tint(Theme.logbook)
            } else if item.todo != nil || item.project != nil {
                Button { sheet = .when([item.id]) } label: { Label("When", systemImage: "calendar") }
                    .tint(Theme.today)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if list == .trash {
                Button(role: .destructive) { store.delete(item.id) } label: { Label("Delete", systemImage: "trash") }
            } else {
                Button(role: .destructive) {
                    withAnimation { store.trash([item.id]) }
                } label: { Label("Delete", systemImage: "trash") }
                Button { sheet = .move([item.id]) } label: { Label("Move", systemImage: "arrow.right") }
                    .tint(Theme.inbox)
            }
        }
    }

    private func open(_ item: Item) {
        switch item {
        case .todo(let todo): router.open(todo.id)
        case .project(let project): router.push(.project(project.id))
        case .area(let area): router.push(.area(area.id))
        default: break
        }
    }

    @ViewBuilder
    private func loggedSection(_ logged: [ToDo], lists: Lists) -> some View {
        Button {
            withAnimation(.snappy) { showLogged.toggle() }
        } label: {
            Text(showLogged ? "Hide logged items" : "Show \(logged.count) logged item\(logged.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        if showLogged {
            ForEach(logged) { todo in
                itemRow(.todo(todo), lists: lists)
            }
        }
    }

    // MARK: - Plus button

    @ViewBuilder
    private var plusButton: some View {
        switch list {
        case .project:
            MagicPlusButton(action: newToDo) {
                Button("New To-Do", systemImage: "checkmark.square") { newToDo() }
                Button("New Heading", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    headingTitle = ""
                    headingPrompt = HeadingPrompt(heading: nil)
                }
            }
        case .area(let id):
            MagicPlusButton(action: newToDo) {
                Button("New To-Do", systemImage: "checkmark.square") { newToDo() }
                Button("New Project", systemImage: "circle.circle") {
                    let project = store.addProject("", area: id)
                    router.focusTitle = project.id
                    router.push(.project(project.id))
                }
            }
        default:
            MagicPlusButton(action: newToDo)
        }
    }

    private func newToDo() {
        let todo = store.addToDo("", in: list, today: model.today)
        if let tagFilter { store.setTags(todo.id, [tagFilter]) }
        router.open(todo.id, isNew: true)
    }

    private func saveHeading() {
        let title = headingTitle.trimmingCharacters(in: .whitespaces)
        if let heading = headingPrompt?.heading {
            store.update(Heading.self, heading.id) { $0.title = title }
        } else if let projectID = list.projectID {
            store.addHeading(title.nonEmpty ?? "New Heading", in: projectID)
        }
        headingPrompt = nil
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(rows: [FlatRow]) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if isEditing {
                Button("Done") {
                    selection = []
                    withAnimation { editMode = .inactive }
                }
                .fontWeight(.semibold)
            } else {
                Menu {
                    Button("Select", systemImage: "checkmark.circle") {
                        withAnimation { editMode = .active }
                    }
                    listActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                let ids = rows.compactMap { $0.item?.id }
                Button(selection.count == ids.count && !ids.isEmpty ? "Deselect All" : "Select All") {
                    selection = selection.count == ids.count ? [] : Set(ids)
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                let ids = Array(selection)
                Button("Complete", systemImage: "checkmark.circle") {
                    store.setStatus(ids, .completed, today: model.today)
                    router.didComplete()
                    selection = []
                }
                Spacer()
                Button("When", systemImage: "calendar") { sheet = .when(ids) }
                Spacer()
                Button("Move", systemImage: "arrow.right.circle") { sheet = .move(ids) }
                Spacer()
                Button("Tags", systemImage: "tag") { sheet = .tags(ids) }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    withAnimation { list == .trash ? ids.forEach(store.delete) : store.trash(ids) }
                    selection = []
                }
            }
        }
    }

    @ViewBuilder
    private var listActions: some View {
        switch list {
        case .project(let id):
            Divider()
            Button("Complete Project", systemImage: "checkmark.circle") {
                store.setStatus([id], .completed, today: model.today)
                router.didComplete()
                router.leave(list)
            }
            Button("When", systemImage: "calendar") { sheet = .when([id]) }
            Button("Deadline", systemImage: "flag") { sheet = .deadline([id]) }
            Button("Add Heading", systemImage: "text.line.first.and.arrowtriangle.forward") {
                headingTitle = ""
                headingPrompt = HeadingPrompt(heading: nil)
            }
            Button("Move", systemImage: "arrow.right.circle") { sheet = .move([id]) }
            Button("Tags", systemImage: "tag") { sheet = .tags([id]) }
            ShareLink(item: store.shareText(for: list, lists: model.lists)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Delete Project", systemImage: "trash", role: .destructive) { confirmDeleteList = true }
        case .area(let id):
            Divider()
            Button("Tags", systemImage: "tag") { sheet = .tags([id]) }
            ShareLink(item: store.shareText(for: list, lists: model.lists)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Delete Area", systemImage: "trash", role: .destructive) { confirmDeleteList = true }
        case .trash:
            Divider()
            Button("Empty Trash", systemImage: "trash.slash", role: .destructive) { confirmEmptyTrash = true }
        case .logbook:
            Divider()
            Button("Show Trash", systemImage: "trash") { router.push(.trash) }
        default:
            ShareLink(item: store.shareText(for: list, lists: model.lists)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var listEntityExists: Bool {
        switch list {
        case .project(let id): store.project(id).map { !$0.isTrashed } ?? false
        case .area(let id): store.area(id).map { !$0.isTrashed } ?? false
        case .tag(let id): store.tag(id) != nil
        default: true
        }
    }

    private var deleteListTitle: String {
        list.projectID != nil ? "Delete this project and its to-dos?" : "Delete this area with its projects and to-dos?"
    }

    private func trashList() {
        switch list {
        case .project(let id), .area(let id): store.trash([id])
        default: break
        }
        router.leave(list)
    }

    // MARK: - Reordering

    /// Applies a drag: reorders within groups, and moving across a heading
    /// changes what the item *is* — evening vs. day in Today, a heading in a
    /// project, a date in Upcoming, Someday in "Later".
    private func move(_ source: IndexSet, to destination: Int, rows: [FlatRow], groups: [ItemGroup]) {
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)

        var newGroups: [[Item]] = Array(repeating: [], count: groups.count)
        // Rows above the first visible header belong to the first headerless group.
        var group = rows.first.map { $0.item != nil ? $0.group : 0 } ?? 0
        for row in moved {
            switch row.kind {
            case .header: group = row.group
            case .item(let item): newGroups[group].append(item)
            }
        }

        let originalGroup = Dictionary(rows.compactMap { row in row.item.map { ($0.id, row.group) } }, uniquingKeysWith: { a, _ in a })
        var changes: [(item: Item, from: Int, to: Int)] = []
        for (index, items) in newGroups.enumerated() {
            for item in items where originalGroup[item.id] != index {
                changes.append((item, originalGroup[item.id] ?? index, index))
            }
        }

        // Validate cross-group moves before touching anything.
        for change in changes {
            let target = groups[change.to].header
            switch list {
            case .today:
                break
            case .upcoming:
                guard case .day = target else { return }
            case .project:
                guard change.item.todo != nil else { return }
            case .area:
                // Group 0 holds projects; the rest hold to-dos.
                if change.item.project != nil || change.to == 0 { return }
            default:
                return
            }
        }

        let key = (list == .today || list == .upcoming) ? Key.todayIndex : Key.index
        store.batch {
            for change in changes {
                let id = change.item.id
                let target = groups[change.to].header
                let source = groups[change.from].header
                switch list {
                case .today:
                    store.schedule([id], target == .evening ? .evening : .today, today: model.today)
                case .upcoming:
                    if case .day(let day) = target { store.schedule([id], .date(day), today: model.today) }
                case .project(let projectID):
                    switch target {
                    case .later:
                        store.schedule([id], .someday, today: model.today)
                    case .heading(let heading):
                        store.move([id], to: .project(projectID, heading: heading.id))
                        if source == .later { store.schedule([id], .anytime, today: model.today) }
                    default:
                        store.move([id], to: .project(projectID, heading: nil))
                        if source == .later { store.schedule([id], .anytime, today: model.today) }
                    }
                case .area:
                    if target == .later {
                        store.schedule([id], .someday, today: model.today)
                    } else if source == .later {
                        store.schedule([id], .anytime, today: model.today)
                    }
                default:
                    break
                }
            }
            for (index, items) in newGroups.enumerated() where items.map(\.id) != groups[index].items.map(\.id) {
                store.reorder(items.map(\.id), key: key)
            }
        }
    }
}

/// Opens a row on tap, except in edit mode where taps select.
private struct TapToOpen: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

/// The faded icon and message shown in an empty list.
struct EmptyListView: View {
    let list: ListID
    var filtered = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: list.systemImage)
                .font(.system(size: 54))
                .foregroundStyle(list.tint.opacity(0.25))
            Text(filtered ? "Nothing here has this tag." : list.emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}
