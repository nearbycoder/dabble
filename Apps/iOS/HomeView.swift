import DabbleKit
import SwiftUI

/// The list of lists: built-in lists, then areas with their projects.
/// The iPhone root, and the iPad sidebar when given a selection.
struct HomeView: View {
    var selection: Binding<ListID?>? = nil
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var editMode: EditMode = .inactive
    @State private var confirmTrash: Item?

    private var store: DabbleStore { model.store }
    private var isSidebar: Bool { selection != nil }

    var body: some View {
        @Bindable var router = router
        Group {
            if let selection {
                List(selection: selection) { content }
                    .listStyle(.sidebar)
            } else {
                List { content }
                    .listStyle(.insetGrouped)
                    .contentMargins(.top, 4, for: .scrollContent)
            }
        }
        .environment(\.editMode, $editMode)
        .searchable(text: $router.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Quick Find")
        .navigationTitle("Dabble")
        .navigationBarTitleDisplayMode(isSidebar ? .automatic : .inline)
        .toolbar { toolbar }
        .refreshable {
            model.sync.syncNow()
            try? await Task.sleep(for: .milliseconds(700))
        }
        .overlay(alignment: .bottomTrailing) {
            if !isSidebar && !editMode.isEditing && router.searchText.isEmpty {
                MagicPlusButton(action: newToDo) { newMenu }
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
        }
        .confirmationDialog("Move to Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }),
                            presenting: confirmTrash) { item in
            Button("Delete “\(store.title(of: item))”", role: .destructive) { store.trash([item.id]) }
        } message: { item in
            Text(item.project != nil ? "The project and its to-dos move to the Trash." : "The area, its projects and to-dos move to the Trash.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !router.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResults(query: router.searchText)
        } else if editMode.isEditing {
            editingContent
        } else {
            listsContent
        }
    }

    // MARK: - Normal

    @ViewBuilder
    private var listsContent: some View {
        let lists = model.lists
        let snapshot = lists.snapshot
        Section {
            row(.inbox, count: lists.inboxCount)
        }
        Section {
            row(.today, count: lists.todayCount, due: lists.todayDueCount)
            row(.upcoming)
            row(.anytime)
            row(.someday)
        }
        Section {
            row(.logbook)
            row(.trash)
        }
        let loose = snapshot.openProjects(in: nil)
        if !loose.isEmpty {
            Section {
                ForEach(loose) { project in
                    projectRow(project, lists: lists)
                }
            }
        }
        ForEach(snapshot.areaList) { area in
            Section {
                NavigationLink(value: ListID.area(area.id)) {
                    Label {
                        Text(area.title.nonEmpty ?? "New Area")
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: "shippingbox.fill").foregroundStyle(Theme.area)
                    }
                }
                .contextMenu { areaMenu(area) }
                ForEach(snapshot.openProjects(in: area.id)) { project in
                    projectRow(project, lists: lists)
                }
            }
        }
    }

    private func row(_ list: ListID, count: Int = 0, due: Int = 0) -> some View {
        NavigationLink(value: list) {
            HStack {
                Label {
                    Text(list.title(in: store))
                } icon: {
                    ListIcon(list: list, size: 20)
                }
                Spacer()
                if due > 0 {
                    CountBadge(count: due)
                }
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func projectRow(_ project: Project, lists: Lists) -> some View {
        NavigationLink(value: ListID.project(project.id)) {
            HStack {
                Label {
                    Text(project.title.nonEmpty ?? "New Project")
                } icon: {
                    ListIcon(list: .project(project.id), size: 20)
                }
                Spacer()
                if let deadline = project.deadline, deadline <= lists.today {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.deadline)
                }
            }
        }
        .contextMenu {
            Button("Complete Project", systemImage: "checkmark.circle") {
                store.setStatus([project.id], .completed, today: model.today)
                router.didComplete()
            }
            Button("Delete Project", systemImage: "trash", role: .destructive) { confirmTrash = .project(project) }
        }
    }

    @ViewBuilder
    private func areaMenu(_ area: Area) -> some View {
        Button("New Project in Area", systemImage: "plus") { newProject(in: area.id) }
        Button("Delete Area", systemImage: "trash", role: .destructive) { confirmTrash = .area(area) }
    }

    // MARK: - Editing

    @ViewBuilder
    private var editingContent: some View {
        let snapshot = store.snapshot
        let loose = snapshot.openProjects(in: nil)
        if !loose.isEmpty {
            Section("Projects") {
                projectEditRows(loose)
            }
        }
        ForEach(snapshot.areaList) { area in
            let projects = snapshot.openProjects(in: area.id)
            if !projects.isEmpty {
                Section(area.title.nonEmpty ?? "New Area") {
                    projectEditRows(projects)
                }
            }
        }
        let areas = snapshot.areaList
        if !areas.isEmpty {
            Section("Areas") {
                ForEach(areas) { area in
                    Label(area.title.nonEmpty ?? "New Area", systemImage: "shippingbox.fill")
                }
                .onMove { source, destination in
                    var ids = areas.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    store.reorder(ids)
                }
                .onDelete { offsets in
                    store.trash(offsets.map { areas[$0].id })
                }
            }
        }
    }

    private func projectEditRows(_ projects: [Project]) -> some View {
        ForEach(projects) { project in
            Label {
                Text(project.title.nonEmpty ?? "New Project")
            } icon: {
                ListIcon(list: .project(project.id), size: 20)
            }
        }
        .onMove { source, destination in
            var ids = projects.map(\.id)
            ids.move(fromOffsets: source, toOffset: destination)
            store.reorder(ids)
        }
        .onDelete { offsets in
            store.trash(offsets.map { projects[$0].id })
        }
    }

    // MARK: - Toolbar & creation

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                router.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(editMode.isEditing ? "Done" : "Edit") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .fontWeight(editMode.isEditing ? .semibold : .regular)
        }
        if isSidebar {
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    newMenu
                } label: {
                    Label("New", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    @ViewBuilder
    private var newMenu: some View {
        Button("New To-Do", systemImage: "checkmark.square") { newToDo() }
        Button("New Project", systemImage: "circle.circle") { newProject(in: nil) }
        Button("New Area", systemImage: "shippingbox") { newArea() }
    }

    private func newToDo() {
        let todo = store.addToDo("", in: .inbox, today: model.today)
        router.open(todo.id, isNew: true)
    }

    private func newProject(in area: UUID?) {
        let project = store.addProject("", area: area)
        router.focusTitle = project.id
        router.show(.project(project.id))
    }

    private func newArea() {
        let area = store.addArea("")
        router.focusTitle = area.id
        router.show(.area(area.id))
    }
}

// MARK: - Quick Find

/// Quick Find results: lists, areas, projects, tags and to-dos.
struct SearchResults: View {
    let query: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let lists = model.lists
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let builtIn = ListID.builtIn.filter { $0.title(in: model.store).localizedCaseInsensitiveContains(trimmed) }
        let results = lists.search(trimmed)
        let containers = results.filter { if case .todo = $0 { false } else { true } }
        let open = results.compactMap(\.todo).filter(\.isOpen)
        let done = results.compactMap(\.todo).filter { !$0.isOpen }

        if builtIn.isEmpty && results.isEmpty {
            ContentUnavailableView.search(text: trimmed)
                .listRowBackground(Color.clear)
        }
        if !builtIn.isEmpty || !containers.isEmpty {
            Section("Lists") {
                ForEach(builtIn, id: \.self) { list in
                    NavigationLink(value: list) {
                        Label { Text(list.title(in: model.store)) } icon: { ListIcon(list: list, size: 20) }
                    }
                }
                ForEach(containers) { item in
                    containerRow(item)
                }
            }
        }
        if !open.isEmpty {
            Section("To-Dos") {
                ForEach(open) { todo in todoRow(todo, lists: lists) }
            }
        }
        if !done.isEmpty {
            Section("Completed") {
                ForEach(done) { todo in todoRow(todo, lists: lists) }
            }
        }
    }

    @ViewBuilder
    private func containerRow(_ item: Item) -> some View {
        switch item {
        case .area(let area):
            NavigationLink(value: ListID.area(area.id)) {
                Label { Text(area.title) } icon: { Image(systemName: "shippingbox.fill").foregroundStyle(Theme.area) }
            }
        case .project(let project):
            NavigationLink(value: ListID.project(project.id)) {
                Label { Text(project.title.nonEmpty ?? "New Project") } icon: { ListIcon(list: .project(project.id), size: 20) }
            }
        case .tag(let tag):
            NavigationLink(value: ListID.tag(tag.id)) {
                Label { Text(tag.title) } icon: { Image(systemName: "tag.fill").foregroundStyle(.secondary) }
            }
        default:
            EmptyView()
        }
    }

    private func todoRow(_ todo: ToDo, lists: Lists) -> some View {
        Button {
            router.open(todo.id)
        } label: {
            HStack(spacing: 12) {
                CheckBox(status: todo.status, size: 19) {
                    model.store.toggleCompleted(todo.id)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.title.nonEmpty ?? "New To-Do")
                        .foregroundStyle(todo.isOpen ? .primary : .secondary)
                    if let place = location(of: todo, snapshot: lists.snapshot, today: lists.today) {
                        Text(place)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func location(of todo: ToDo, snapshot: Snapshot, today: Day) -> String? {
        if let projectID = todo.projectID, let project = snapshot.projects[projectID] { return project.title }
        if let areaID = todo.areaID, let area = snapshot.areas[areaID] { return area.title }
        if todo.start == .inbox { return "Inbox" }
        return todo.whenDescription(today: today)?.title
    }
}
