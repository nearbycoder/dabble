import DabbleKit
import SwiftUI

/// Toggle tags on one or more items, or create a new one by typing it.
struct TagPicker: View {
    let ids: [UUID]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var store: DabbleStore { model.store }

    var body: some View {
        let snapshot = store.snapshot
        let tags = snapshot.tagList.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let exists = snapshot.tags.values.contains { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
        NavigationStack {
            List {
                if !trimmed.isEmpty && !exists {
                    Button {
                        let tag = store.addTag(trimmed)
                        store.toggleTag(tag.id, on: ids)
                        query = ""
                    } label: {
                        Label("Create “\(trimmed)”", systemImage: "plus.circle.fill")
                    }
                }
                ForEach(tags) { tag in
                    let state = selection(of: tag.id)
                    Button {
                        store.toggleTag(tag.id, on: ids)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tag.fill")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                            Text(tag.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            switch state {
                            case .all: Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                            case .some: Image(systemName: "minus").fontWeight(.semibold).foregroundStyle(.secondary)
                            case .none: EmptyView()
                            }
                        }
                        .padding(.leading, query.isEmpty ? CGFloat(snapshot.tagDepth(tag)) * 18 : 0)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if tags.isEmpty && trimmed.isEmpty {
                    Text("No tags yet. Type a name above to create one.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or create a tag")
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private enum Coverage { case all, some, none }

    private func selection(of tag: UUID) -> Coverage {
        let has = ids.map { id in
            (store.todo(id)?.tagIDs ?? store.project(id)?.tagIDs ?? store.area(id)?.tagIDs ?? []).contains(tag)
        }
        if has.allSatisfy({ $0 }) { return .all }
        return has.contains(true) ? .some : .none
    }
}
