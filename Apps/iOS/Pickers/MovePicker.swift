import DabbleKit
import SwiftUI

/// Move to-dos to the Inbox, an area, a project or a heading; projects to an area.
struct MovePicker: View {
    let ids: [UUID]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var store: DabbleStore { model.store }
    private var movingProjects: Bool { ids.allSatisfy { store.project($0) != nil } }

    /// Where a single item currently lives, for the checkmark.
    private var current: Destination? {
        guard ids.count == 1 else { return nil }
        if let todo = store.todo(ids[0]) {
            if let project = todo.projectID { return .project(project, heading: todo.headingID) }
            if let area = todo.areaID { return .area(area) }
            return todo.start == .inbox ? .inbox : Destination.none
        }
        if let project = store.project(ids[0]) {
            return project.areaID.map(Destination.area) ?? Destination.none
        }
        return nil
    }

    var body: some View {
        let snapshot = store.snapshot
        NavigationStack {
            List {
                if movingProjects {
                    Section {
                        PickerRow(title: "No Area", systemImage: "circle.dashed", tint: .secondary, isSelected: current == Destination.none) { move(.none) }
                    }
                    Section("Areas") {
                        ForEach(snapshot.areaList.filter(matches)) { area in
                            PickerRow(title: area.title.nonEmpty ?? "New Area", systemImage: "shippingbox.fill", tint: Theme.area, isSelected: current == .area(area.id)) { move(.area(area.id)) }
                        }
                    }
                } else {
                    Section {
                        PickerRow(title: "Inbox", systemImage: "tray.fill", tint: Theme.inbox, isSelected: current == .inbox) { move(.inbox) }
                        PickerRow(title: "No Project", systemImage: "circle.dashed", tint: .secondary, isSelected: current == Destination.none) { move(.none) }
                    }
                    let loose = snapshot.openProjects(in: nil)
                    if !loose.isEmpty {
                        Section("Projects") {
                            ForEach(loose) { projectRows($0, snapshot: snapshot) }
                        }
                    }
                    ForEach(snapshot.areaList) { area in
                        Section {
                            if matches(area) {
                                PickerRow(title: area.title.nonEmpty ?? "New Area", systemImage: "shippingbox.fill", tint: Theme.area, isSelected: current == .area(area.id)) { move(.area(area.id)) }
                            }
                            ForEach(snapshot.openProjects(in: area.id)) { projectRows($0, snapshot: snapshot) }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func projectRows(_ project: Project, snapshot: Snapshot) -> some View {
        let headings = snapshot.headings(in: project.id).filter { !$0.isArchived }
        let projectMatches = query.isEmpty || project.title.localizedCaseInsensitiveContains(query)
        if projectMatches || headings.contains(where: { $0.title.localizedCaseInsensitiveContains(query) }) {
            let progress = snapshot.progress(of: project.id)
            Button {
                move(.project(project.id, heading: nil))
            } label: {
                HStack(spacing: 12) {
                    ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 18)
                        .frame(width: 24)
                    Text(project.title.nonEmpty ?? "New Project").foregroundStyle(.primary)
                    Spacer()
                    if current == .project(project.id, heading: nil) {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(headings) { heading in
                PickerRow(title: heading.title.nonEmpty ?? "Heading", systemImage: "list.bullet.indent", tint: .secondary,
                          isSelected: current == .project(project.id, heading: heading.id), indent: 28) {
                    move(.project(project.id, heading: heading.id))
                }
            }
        }
    }

    private func matches(_ area: Area) -> Bool {
        query.isEmpty || area.title.localizedCaseInsensitiveContains(query)
    }

    private func move(_ destination: Destination) {
        store.move(ids, to: destination)
        dismiss()
    }
}
