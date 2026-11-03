import DabbleKit
import SwiftUI

/// One to-do in a list: checkbox, title, and Things-style chips.
struct ToDoRow: View {
    let todo: ToDo
    let list: ListID
    let lists: Lists
    var isEditing = false
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let snapshot = lists.snapshot
        let today = lists.today
        let checklist = snapshot.checklistProgress(of: todo.id)
        let tags = snapshot.tags(of: .todo(todo))
        let container = containerTitle(snapshot)
        let when = whenChip(today: today)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            CheckBox(status: todo.status, tint: .secondary, size: 21) {
                complete()
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            .keyframeAnimator(initialValue: 1.0, trigger: todo.status) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.25, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.3)
            }
            .allowsHitTesting(!isEditing)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let when {
                        if when.compact {
                            Image(systemName: when.systemImage)
                                .font(.caption)
                                .foregroundStyle(when.tint)
                        } else {
                            Chip(title: when.title, systemImage: when.systemImage, tint: when.tint)
                        }
                    }
                    Text(todo.title.nonEmpty ?? "New To-Do")
                        .foregroundStyle(todo.isOpen && !todo.title.isEmpty ? .primary : .secondary)
                        .lineLimit(3)
                    indicators(checklist: checklist)
                    Spacer(minLength: 0)
                }
                if container != nil || !tags.isEmpty || todo.deadline != nil {
                    HStack(spacing: 6) {
                        if let container {
                            Text(container)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ForEach(tags) { TagPill(title: $0.title) }
                        Spacer(minLength: 0)
                        if let deadline = todo.deadline, todo.isOpen {
                            DeadlineLabel(deadline: deadline, today: today)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .opacity(todo.isOpen || !lists.keep.contains(todo.id) ? 1 : 0.65)
        .animation(.easeOut(duration: 0.25), value: todo.status)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func indicators(checklist: (done: Int, total: Int)) -> some View {
        let icons: [String] = [
            todo.notes.isEmpty ? nil : "doc.text",
            checklist.total > 0 ? "checklist" : nil,
            todo.repeatRule != nil || todo.repeatSeries != nil ? "arrow.triangle.2.circlepath" : nil,
            todo.reminder != nil ? "bell.fill" : nil,
        ].compactMap { $0 }
        ForEach(icons, id: \.self) { icon in
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func complete() {
        let wasOpen = todo.isOpen
        withAnimation(.snappy) {
            model.store.setStatus([todo.id], wasOpen ? .completed : .open, today: model.today)
        }
        if wasOpen { router.didComplete() }
    }

    /// "Today"/"This Evening" become a star or moon outside Today; future dates a chip.
    private func whenChip(today: Day) -> (title: String, systemImage: String, tint: Color, compact: Bool)? {
        guard todo.isOpen, let info = todo.whenDescription(today: today) else { return nil }
        if let date = todo.startDate {
            if date <= today {
                return list == .today ? nil : (info.title, info.systemImage, info.tint, true)
            }
            return list == .upcoming ? nil : (date.shortLabel(today: today), "calendar", .secondary, false)
        }
        return nil
    }

    private func containerTitle(_ snapshot: Snapshot) -> String? {
        guard list.showsContainer || list == .anytime && todo.projectID == nil && todo.areaID == nil else { return nil }
        if let projectID = todo.projectID, let project = snapshot.projects[projectID] {
            if let headingID = todo.headingID, let heading = snapshot.headings[headingID], list != .today {
                return "\(project.title.nonEmpty ?? "New Project") › \(heading.title)"
            }
            return project.title.nonEmpty ?? "New Project"
        }
        if let areaID = todo.areaID, let area = snapshot.areas[areaID] { return area.title }
        if list != .inbox && todo.start == .inbox { return "Inbox" }
        return nil
    }
}

/// Flag + "3 days left", red once it's due.
struct DeadlineLabel: View {
    let deadline: Day
    let today: Day

    var body: some View {
        let due = deadline <= today
        Label(deadline.deadlineLabel(today: today), systemImage: "flag.fill")
            .font(.caption.weight(due ? .semibold : .regular))
            .foregroundStyle(due ? Theme.deadline : .secondary)
            .lineLimit(1)
    }
}

/// A project shown inside a list (Today, an area, Someday…).
struct ProjectRow: View {
    let project: Project
    let list: ListID
    let lists: Lists

    var body: some View {
        let snapshot = lists.snapshot
        let progress = snapshot.progress(of: project.id)
        let area = project.areaID.flatMap { snapshot.areas[$0] }
        HStack(spacing: 12) {
            ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total),
                        size: 21, completed: project.status == .completed)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if list != .today, project.isOpen, let when = project.whenDescription(today: lists.today), project.startDate.map({ $0 <= lists.today }) ?? false {
                        Image(systemName: when.systemImage).font(.caption).foregroundStyle(when.tint)
                    }
                    Text(project.title.nonEmpty ?? "New Project")
                        .fontWeight(.semibold)
                        .foregroundStyle(project.isOpen ? .primary : .secondary)
                        .lineLimit(2)
                }
                if list.showsContainer, let area {
                    Text(area.title).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let deadline = project.deadline, project.isOpen {
                DeadlineLabel(deadline: deadline, today: lists.today)
            }
            let open = lists.openCount(project: project.id)
            if open > 0 && list != .trash {
                Text("\(open)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// An area row, only seen in the Trash.
struct AreaRow: View {
    let area: Area

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Theme.area)
                .frame(width: 21)
            Text(area.title.nonEmpty ?? "New Area")
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Group headers

/// Section headings inside a list, drawn as rows so items can be dragged across them.
struct GroupHeaderRow: View {
    let header: GroupHeader
    let list: ListID
    let lists: Lists
    var onRename: ((Heading) -> Void)?
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model

    var body: some View {
        switch header {
        case .none:
            Color.clear.frame(height: 6)
        case .evening:
            titled {
                Label {
                    Text("This Evening")
                } icon: {
                    Image(systemName: "moon.fill").foregroundStyle(Theme.evening)
                }
                .font(.headline)
            }
        case .area(let area):
            Button {
                router.push(.area(area.id))
            } label: {
                titled {
                    Label {
                        Text(area.title.nonEmpty ?? "New Area").foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "shippingbox.fill").foregroundStyle(Theme.area)
                    }
                    .font(.headline)
                }
            }
            .buttonStyle(.plain)
        case .project(let project):
            Button {
                router.push(.project(project.id))
            } label: {
                titled {
                    HStack(spacing: 8) {
                        let progress = lists.snapshot.progress(of: project.id)
                        ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 15)
                        Text(project.title.nonEmpty ?? "New Project")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        case .heading(let heading):
            titled(accent: true) {
                Text(heading.title.nonEmpty ?? "Untitled Heading")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Rename", systemImage: "pencil") { onRename?(heading) }
                Button("Delete Heading", systemImage: "trash", role: .destructive) {
                    model.store.trash([heading.id])
                }
            }
        case .day(let day):
            if list == .upcoming {
                upcomingDay(day)
            } else {
                titled {
                    Text(logbookLabel(day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        case .month(let year, let month):
            titled {
                Text(Day(year: year, month: month, day: 1).date().formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
            }
        case .later:
            titled {
                Label("Later", systemImage: "archivebox.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.someday)
            }
        case .completed:
            titled {
                Text("Completed").font(.headline).foregroundStyle(.secondary)
            }
        }
    }

    private func titled<Content: View>(accent: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Rectangle()
                .fill(accent ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    private func upcomingDay(_ day: Day) -> some View {
        let offset = lists.today.days(until: day)
        let label: String
        if offset == 1 {
            label = "Tomorrow"
        } else if offset < 7 {
            label = day.date().formatted(.dateTime.weekday(.wide))
        } else {
            label = day.date().formatted(.dateTime.weekday(.wide).month(.abbreviated))
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(day.day)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
        }
        .padding(.top, 14)
    }

    private func logbookLabel(_ day: Day) -> String {
        let offset = day.days(until: lists.today)
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            if day.year == lists.today.year {
                return day.date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
            return day.date().formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}
