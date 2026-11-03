import DabbleKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var importing = false
    @State private var backup: BackupDocument?
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        SettingsLabel(title: "Sync", systemImage: "arrow.triangle.2.circlepath", tint: .blue) {
                            Text(syncSummary).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Your devices sync directly with each other. No server, no account.")
                }

                Section("General") {
                    Picker(selection: $model.logbookPolicy) {
                        Text("Immediately").tag(LogbookPolicy.immediately)
                        Text("Daily").tag(LogbookPolicy.daily)
                    } label: {
                        SettingsLabel(title: "Move to Logbook", systemImage: "checkmark.rectangle.stack.fill", tint: Theme.logbook) { EmptyView() }
                    }
                    NavigationLink {
                        TagsSettingsView()
                    } label: {
                        SettingsLabel(title: "Tags", systemImage: "tag.fill", tint: .gray) {
                            Text("\(model.store.snapshot.tags.count)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        do {
                            backup = BackupDocument(data: try model.store.exportData())
                            exporting = true
                        } catch {
                            message = "Couldn't create a backup: \(error.localizedDescription)"
                        }
                    } label: {
                        SettingsLabel(title: "Export Backup…", systemImage: "square.and.arrow.up", tint: .indigo) { EmptyView() }
                    }
                    Button {
                        importing = true
                    } label: {
                        SettingsLabel(title: "Import Backup…", systemImage: "square.and.arrow.down", tint: .indigo) { EmptyView() }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Backups are JSON files. Importing merges a backup into your data — nothing is overwritten or removed.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://github.com/nearbycoder/dabble")!) {
                        HStack {
                            SettingsLabel(title: "Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right", tint: Color(white: 0.2)) { EmptyView() }
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    LabeledContent("License", value: "MIT")
                }

                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.tint)
                        Text("Dabble")
                            .font(.headline)
                        Text("An open-source to-do app inspired by Things.\nYour data stays on your devices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .fileExporter(isPresented: $exporting, document: backup, contentType: .json,
                          defaultFilename: "Dabble Backup \(Day.today)") { result in
                if case .failure(let error) = result { message = "Export failed: \(error.localizedDescription)" }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                importBackup(result)
            }
            .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var syncSummary: String {
        let sync = model.sync
        if !sync.isEnabled { return "Off" }
        if !sync.hasGroup { return "Not set up" }
        let connected = sync.peers.filter(\.isConnected).count
        return connected > 0 ? "\(connected) connected" : "\(sync.peers.count) device\(sync.peers.count == 1 ? "" : "s")"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func importBackup(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let before = model.store.records.count
                try model.store.importData(data)
                let added = model.store.records.count - before
                message = added > 0 ? "Imported \(added) new item\(added == 1 ? "" : "s")." : "Backup merged. Everything was already up to date."
            } catch {
                message = "That file isn't a Dabble backup."
            }
        case .failure(let error):
            message = "Couldn't open the file: \(error.localizedDescription)"
        }
    }
}

/// Settings-style label: a white glyph on a colored rounded square.
struct SettingsLabel<Accessory: View>: View {
    var title: String
    var systemImage: String
    var tint: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            Text(title)
            Spacer(minLength: 0)
            accessory()
        }
    }
}

nonisolated struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Tags

struct TagsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var newTagName = ""
    @State private var addingTag = false

    var body: some View {
        let snapshot = model.store.snapshot
        let tags = snapshot.tagList
        List {
            if tags.isEmpty {
                ContentUnavailableView("No Tags", systemImage: "tag", description: Text("Tags help you filter lists, like “Errands” or “Waiting”."))
            }
            ForEach(tags) { tag in
                NavigationLink {
                    TagEditor(id: tag.id)
                } label: {
                    Label(tag.title, systemImage: snapshot.tagDepth(tag) == 0 ? "tag.fill" : "arrow.turn.down.right")
                        .padding(.leading, CGFloat(snapshot.tagDepth(tag)) * 20)
                }
            }
            .onDelete { offsets in
                for offset in offsets { model.store.delete(tags[offset].id) }
            }
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Tag", systemImage: "plus") {
                    newTagName = ""
                    addingTag = true
                }
            }
        }
        .alert("New Tag", isPresented: $addingTag) {
            TextField("Name", text: $newTagName)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let name = newTagName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.store.addTag(name) }
            }
        }
    }
}

/// Rename a tag, nest it under another, or delete it.
struct TagEditor: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        let store = model.store
        let snapshot = store.snapshot
        if let tag = store.tag(id) {
            let family = snapshot.tagFamily(id)
            Form {
                Section("Name") {
                    EditableText(placeholder: "Tag", value: tag.title) { title in
                        let trimmed = title.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { store.update(Tag.self, id) { $0.title = trimmed } }
                    }
                }
                Section {
                    Picker("Parent Tag", selection: Binding(
                        get: { store.tag(id)?.parentID },
                        set: { parent in store.update(Tag.self, id) { $0.parentID = parent } }
                    )) {
                        Text("None").tag(UUID?.none)
                        ForEach(snapshot.tagList.filter { !family.contains($0.id) }) { other in
                            Text(String(repeating: "  ", count: snapshot.tagDepth(other)) + other.title).tag(UUID?.some(other.id))
                        }
                    }
                } footer: {
                    Text("Filtering by a parent tag also shows items tagged with its children.")
                }
                Section {
                    Button("Delete Tag", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(tag.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete “\(tag.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Tag", role: .destructive) {
                    store.delete(id)
                    dismiss()
                }
            } message: {
                Text("The tag and its child tags are removed from every item.")
            }
        } else {
            ContentUnavailableView("Tag Deleted", systemImage: "tag.slash")
        }
    }
}
