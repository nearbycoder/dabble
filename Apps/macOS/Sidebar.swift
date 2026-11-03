import AppKit
import DabbleKit
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        let lists = model.lists
        let snapshot = model.store.snapshot
        let looseProjects = snapshot.openProjects(in: nil)
        List(selection: $state.list) {
            Section {
                SidebarRow(list: .inbox, count: lists.inboxCount)
            }
            Section {
                SidebarRow(list: .today, count: lists.todayCount, due: lists.todayDueCount)
                SidebarRow(list: .upcoming)
                SidebarRow(list: .anytime)
                SidebarRow(list: .someday)
            }
            Section {
                SidebarRow(list: .logbook)
                SidebarRow(list: .trash)
            }
            if !looseProjects.isEmpty {
                Section {
                    ForEach(looseProjects) { project in
                        SidebarRow(list: .project(project.id), count: lists.openCount(project: project.id), dimCount: true)
                    }
                }
            }
            ForEach(snapshot.areaList) { area in
                Section {
                    SidebarRow(list: .area(area.id))
                    ForEach(snapshot.openProjects(in: area.id)) { project in
                        SidebarRow(list: .project(project.id), count: lists.openCount(project: project.id), dimCount: true)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarBottomBar() }
    }
}

struct SidebarRow: View {
    let list: ListID
    var count = 0
    var due = 0
    var dimCount = false
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            ListIcon(list: list, size: 15)
            Text(list.title(in: model.store))
                .fontWeight(isArea ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            if due > 0 {
                Text("\(due)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.deadline))
            }
            if count > 0 && !dimCount {
                Text("\(count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? Color.accentColor.opacity(0.25) : .clear))
        .tag(list)
        .dropDestination(for: URL.self) { urls, _ in
            let ids = urls.flatMap { DragPayload.ids(from: $0) }
            guard !ids.isEmpty else { return false }
            state.drop(ids, on: list)
            return true
        } isTargeted: { targeted = $0 }
        .modifier(SidebarDragSource(list: list))
        .contextMenu { menu }
    }

    private var isArea: Bool {
        if case .area = list { return true }
        return false
    }

    @ViewBuilder
    private var menu: some View {
        let store = model.store
        switch list {
        case .project(let id):
            Button("Open") { state.navigate(to: list) }
            Button("Rename") {
                state.navigate(to: list)
                state.focusHeaderTitle = true
            }
            Button("Open in New Window") { NewWindowRequest.open(list) }
            Divider()
            Button("Complete Project") { state.toggleComplete([id]) }
            Button("Cancel Project") { state.toggleCanceled([id]) }
            Menu("Move to Area") {
                Button("No Area") { store.move([id], to: .none) }
                Divider()
                ForEach(store.snapshot.areaList) { area in
                    Button(area.title.nonEmpty ?? "New Area") { store.move([id], to: .area(area.id)) }
                }
            }
            Divider()
            Button("Delete Project", role: .destructive) {
                store.trash([id])
                if state.current == list { state.navigate(to: .today) }
            }
        case .area(let id):
            Button("Open") { state.navigate(to: list) }
            Button("Rename") {
                state.navigate(to: list)
                state.focusHeaderTitle = true
            }
            Button("New Project in Area") {
                state.navigate(to: list)
                state.newProject()
            }
            Divider()
            Button("Delete Area", role: .destructive) {
                store.trash([id])
                if state.current == list { state.navigate(to: .today) }
            }
        case .trash:
            Button("Empty Trash", role: .destructive) { store.emptyTrash() }
        case .logbook:
            Button("Log Completed Now") { store.logCompleted() }
        default:
            Button("Open in New Window") { NewWindowRequest.open(list) }
        }
    }
}

/// Projects and areas in the sidebar can be dragged to reorder or regroup.
private struct SidebarDragSource: ViewModifier {
    let list: ListID

    func body(content: Content) -> some View {
        switch list {
        case .project(let id), .area(let id):
            content.onDrag { DragPayload.provider([id]) }
        default:
            content
        }
    }
}

struct SidebarBottomBar: View {
    @Environment(WindowState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Project") { state.newProject() }
                Button("New Area") { state.newArea() }
            } label: {
                Label("New List", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Project (⌥⌘N) or Area")
            Spacer()
            SyncIndicator()
            SettingsButton()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }
}

struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { openSettings() } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .help("Settings")
    }
}

/// A dot in the sidebar showing whether this Mac is syncing with anything.
struct SyncIndicator: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = SettingsTab.general

    var body: some View {
        let sync = model.sync
        let connected = sync.peers.filter(\.isConnected)
        Button {
            settingsTab = .sync
            openSettings()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: sync.isEnabled ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(color(sync: sync, connected: connected.count))
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: 1)
            }
        }
        .buttonStyle(.borderless)
        .help(tooltip(sync: sync, connected: connected))
    }

    private func color(sync: SyncEngine, connected: Int) -> Color {
        if !sync.isEnabled || !sync.hasGroup { return .secondary.opacity(0.5) }
        if sync.lastError != nil && connected == 0 { return .orange }
        return connected > 0 ? .green : .secondary.opacity(0.6)
    }

    private func tooltip(sync: SyncEngine, connected: [SyncEngine.Peer]) -> String {
        if !sync.isEnabled { return "Sync is off" }
        if !sync.hasGroup { return "Not paired with another device yet. Click to set up sync." }
        var lines = connected.isEmpty ? ["No devices connected right now"] : connected.map { "Connected: \($0.name)" }
        if let last = sync.lastSync { lines.append("Last synced \(last.formatted(.relative(presentation: .named)))") }
        if let error = sync.lastError { lines.append(error) }
        return lines.joined(separator: "\n")
    }
}
