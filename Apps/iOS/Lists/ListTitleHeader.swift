import DabbleKit
import SwiftUI

/// The big title at the top of a list, with editable title and notes for
/// projects and areas, like Things.
struct ListTitleHeader: View {
    let list: ListID
    let lists: Lists
    var present: (ItemSheet) -> Void
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                icon
                title
            }
            if case .project(let id) = list, let project = model.store.project(id) {
                projectDetails(project)
            }
            if case .area(let id) = list, let area = model.store.area(id), !area.tagIDs.isEmpty {
                tagRow(lists.snapshot.tags(of: .area(area)), id: id)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var icon: some View {
        switch list {
        case .project(let id):
            let progress = lists.snapshot.progress(of: id)
            ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total),
                        size: 26, completed: model.store.project(id)?.status == .completed)
        case .today:
            Image(systemName: "star.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.today)
        default:
            Image(systemName: list.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(list.tint)
        }
    }

    @ViewBuilder
    private var title: some View {
        switch list {
        case .project(let id):
            EditableText(placeholder: "New Project", value: model.store.project(id)?.title ?? "", autoFocus: router.focusTitle == id) { title in
                model.store.update(Project.self, id) { $0.title = title }
            }
            .font(.largeTitle.bold())
            .onAppear { if router.focusTitle == id { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { router.focusTitle = nil } } }
        case .area(let id):
            EditableText(placeholder: "New Area", value: model.store.area(id)?.title ?? "", autoFocus: router.focusTitle == id) { title in
                model.store.update(Area.self, id) { $0.title = title }
            }
            .font(.largeTitle.bold())
            .onAppear { if router.focusTitle == id { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { router.focusTitle = nil } } }
        default:
            Text(list.title(in: model.store))
                .font(.largeTitle.bold())
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func projectDetails(_ project: Project) -> some View {
        let when = project.whenDescription(today: lists.today)
        if when != nil || project.deadline != nil {
            HStack(spacing: 8) {
                if let when {
                    Button { present(.when([project.id])) } label: {
                        Chip(title: when.title, systemImage: when.systemImage, tint: when.tint)
                    }
                    .buttonStyle(.plain)
                }
                if let deadline = project.deadline {
                    Button { present(.deadline([project.id])) } label: {
                        Chip(title: "Deadline: \(deadline.shortLabel(today: lists.today))", systemImage: "flag.fill",
                             tint: deadline <= lists.today ? Theme.deadline : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !project.tagIDs.isEmpty {
            tagRow(lists.snapshot.tags(of: .project(project)), id: project.id)
        }
        EditableText(placeholder: "Notes", value: project.notes, axis: .vertical) { notes in
            model.store.update(Project.self, project.id) { $0.notes = notes }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1...12)
    }

    private func tagRow(_ tags: [Tag], id: UUID) -> some View {
        Button { present(.tags([id])) } label: {
            FlowLayout(spacing: 6) {
                ForEach(tags) { TagPill(title: $0.title) }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal tag chips that filter the list, shown when items have tags.
struct TagFilterBar: View {
    let tags: [Tag]
    @Binding var selection: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: selection == nil) { selection = nil }
                ForEach(tags) { tag in
                    chip(tag.title, isSelected: selection == tag.id) {
                        selection = selection == tag.id ? nil : tag.id
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12)))
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
