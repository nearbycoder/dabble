import AppKit
import DabbleKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String {
    case general, sync, agents, tags, backup
}

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let defaultsKey = "appearance"

    static func apply() {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? AppAppearance.system.rawValue
        switch AppAppearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.sync)
            AgentSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(SettingsTab.agents)
            TagSettingsView()
                .tabItem { Label("Tags", systemImage: "tag") }
                .tag(SettingsTab.tags)
            BackupSettingsView()
                .tabItem { Label("Backup", systemImage: "externaldrive") }
                .tag(SettingsTab.backup)
        }
        .frame(width: 580)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(QuickEntryController.hotKeyDefaultsKey) private var quickEntryEnabled = true
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system
    @State private var hotKeyFailed = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(AppAppearance.system)
                    Text("Light").tag(AppAppearance.light)
                    Text("Dark").tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { AppAppearance.apply() }
            }
            Section {
                Picker("Move completed items to the Logbook", selection: $model.logbookPolicy) {
                    Text("Immediately").tag(LogbookPolicy.immediately)
                    Text("Daily").tag(LogbookPolicy.daily)
                }
                .pickerStyle(.radioGroup)
                Text("“Daily” keeps checked-off to-dos in their lists until the end of the day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $quickEntryEnabled) {
                    HStack {
                        Text("Quick Entry shortcut")
                        Spacer()
                        Text("⌃Space")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    }
                }
                Text("Press ⌃Space in any app to add a to-do to your Inbox. If macOS uses ⌃Space to switch input sources, change that in System Settings › Keyboard › Keyboard Shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hotKeyFailed {
                    Label("Another app is already using ⌃Space.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Button("Open Quick Entry") { QuickEntryController.shared?.show() }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .onChange(of: quickEntryEnabled) { refreshHotKey() }
        .onAppear { hotKeyFailed = quickEntryEnabled && QuickEntryController.shared?.hotKeyRegistered == false }
    }

    private func refreshHotKey() {
        QuickEntryController.shared?.updateHotKey()
        hotKeyFailed = quickEntryEnabled && QuickEntryController.shared?.hotKeyRegistered == false
    }
}

// MARK: - Tags

struct TagSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        let snapshot = model.store.snapshot
        let tags = snapshot.tagList
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(tags) { tag in
                    TagSettingsRow(tag: tag, depth: snapshot.tagDepth(tag))
                        .tag(tag.id)
                }
                .onMove { source, destination in
                    var order = tags.map(\.id)
                    order.move(fromOffsets: source, toOffset: destination)
                    model.store.reorder(order)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if tags.isEmpty {
                    Text("No tags yet").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 0) {
                Button {
                    let tag = model.store.addTag(uniqueName(in: snapshot))
                    selection = tag.id
                } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                Button {
                    if let selection { model.store.delete(selection) }
                    selection = nil
                } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                .disabled(selection == nil)
                Spacer()
                Text("Drag to reorder. ⌃+shortcut toggles a tag on selected to-dos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(height: 380)
    }

    private func uniqueName(in snapshot: Snapshot) -> String {
        var name = "New Tag"
        var counter = 2
        while snapshot.tags.values.contains(where: { $0.title == name }) {
            name = "New Tag \(counter)"
            counter += 1
        }
        return name
    }
}

struct TagSettingsRow: View {
    let tag: Tag
    let depth: Int
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var shortcut = ""

    var body: some View {
        let snapshot = model.store.snapshot
        HStack(spacing: 8) {
            Image(systemName: "tag.fill")
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(depth) * 18)
            TextField("Tag", text: $title)
                .textFieldStyle(.plain)
                .onSubmit(commitTitle)
            Spacer()
            Menu {
                Button("None") { model.store.update(Tag.self, tag.id) { $0.parentID = nil } }
                Divider()
                let family = snapshot.tagFamily(tag.id)
                ForEach(snapshot.tagList.filter { !family.contains($0.id) }) { parent in
                    Button(String(repeating: "   ", count: snapshot.tagDepth(parent)) + parent.title) {
                        model.store.update(Tag.self, tag.id) { $0.parentID = parent.id }
                    }
                }
            } label: {
                Text(tag.parentID.flatMap { snapshot.tags[$0]?.title }.map { "in \($0)" } ?? "Top level")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Nest under another tag")
            HStack(spacing: 2) {
                Text("⌃").foregroundStyle(.secondary)
                TextField("", text: $shortcut)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 28)
                    .multilineTextAlignment(.center)
                    .onChange(of: shortcut) { _, value in
                        let key = String(value.suffix(1)).lowercased()
                        if key != value { shortcut = key }
                        if key != (tag.shortcut ?? "") {
                            model.store.update(Tag.self, tag.id) { $0.shortcut = key.isEmpty ? nil : key }
                        }
                    }
            }
            .help("Keyboard shortcut")
            Button {
                model.store.delete(tag.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete tag")
        }
        .padding(.vertical, 2)
        .onAppear {
            title = tag.title
            shortcut = tag.shortcut ?? ""
        }
        .onChange(of: tag.title) { _, value in title = value }
        .onChange(of: title) { _, value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed != tag.title { model.store.update(Tag.self, tag.id) { $0.title = trimmed } }
        }
    }

    private func commitTitle() {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = tag.title }
    }
}

// MARK: - Backup

struct BackupSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Export") {
                    Button("Export Backup…", action: export)
                }
                Text("Saves everything — to-dos, projects, areas, tags and their history — as a JSON file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Import") {
                    Button("Import Backup…", action: importBackup)
                }
                Text("Merges a backup into this Mac's data. Nothing is overwritten: the newest version of each change wins, and the result syncs to your other devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .orange : .green)
            }
            Section {
                LabeledContent("Records", value: "\(model.store.records.count)")
                LabeledContent("Data folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DabbleStore.defaultDirectory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Dabble Backup \(Date().formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.exportData().write(to: url, options: .atomic)
            report("Exported to \(url.lastPathComponent)")
        } catch {
            report(error.localizedDescription, error: true)
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let before = model.store.records.count
            try model.store.importData(Data(contentsOf: url))
            report("Imported \(url.lastPathComponent) (\(model.store.records.count - before) new records)")
        } catch {
            report("That file isn't a Dabble backup.", error: true)
        }
    }

    private func report(_ text: String, error: Bool = false) {
        message = text
        isError = error
    }
}
