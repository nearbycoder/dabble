import DabbleKit
import SwiftUI

/// Names, icons and colors shared by the Mac and iOS apps.
extension ListID {
    static let builtIn: [ListID] = [.inbox, .today, .upcoming, .anytime, .someday, .logbook, .trash]

    func title(in store: DabbleStore) -> String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .logbook: "Logbook"
        case .trash: "Trash"
        case .project(let id): store.project(id)?.title.nonEmpty ?? "New Project"
        case .area(let id): store.area(id)?.title.nonEmpty ?? "New Area"
        case .tag(let id): store.tag(id)?.title ?? "Tag"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray.fill"
        case .today: "star.fill"
        case .upcoming: "calendar"
        case .anytime: "square.stack.3d.up.fill"
        case .someday: "archivebox.fill"
        case .logbook: "checkmark.rectangle.stack.fill"
        case .trash: "trash.fill"
        case .project: "circle"
        case .area: "shippingbox.fill"
        case .tag: "tag.fill"
        }
    }

    var tint: Color {
        switch self {
        case .inbox: Theme.inbox
        case .today: Theme.today
        case .upcoming: Theme.upcoming
        case .anytime: Theme.anytime
        case .someday: Theme.someday
        case .logbook: Theme.logbook
        case .trash: .secondary
        case .project: Theme.project
        case .area: Theme.area
        case .tag: .secondary
        }
    }

    /// Placeholder shown when a list is empty.
    var emptyMessage: String {
        switch self {
        case .inbox: "Your Inbox is empty. New to-dos land here until you sort them."
        case .today: "Nothing planned for today. Enjoy it, or pull something in from Anytime."
        case .upcoming: "Nothing scheduled. Give a to-do a date and it shows up here."
        case .anytime: "Everything you could do right now shows up here."
        case .someday: "Ideas and maybes you're not ready to commit to."
        case .logbook: "Completed to-dos are kept here."
        case .trash: "Trash is empty."
        case .project: "No to-dos yet."
        case .area: "No projects or to-dos in this area yet."
        case .tag: "Nothing has this tag."
        }
    }
}

enum Theme {
    static let inbox = Color(red: 0.18, green: 0.53, blue: 0.96)
    static let today = Color(red: 0.98, green: 0.78, blue: 0.10)
    static let evening = Color(red: 0.40, green: 0.55, blue: 0.95)
    static let upcoming = Color(red: 0.93, green: 0.22, blue: 0.33)
    static let anytime = Color(red: 0.24, green: 0.71, blue: 0.67)
    static let someday = Color(red: 0.78, green: 0.66, blue: 0.45)
    static let logbook = Color(red: 0.27, green: 0.70, blue: 0.39)
    static let project = Color(red: 0.30, green: 0.52, blue: 0.95)
    static let area = Color(red: 0.36, green: 0.73, blue: 0.40)
    static let deadline = Color(red: 0.92, green: 0.20, blue: 0.27)
    static let tagBackground = Color.secondary.opacity(0.14)
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Day {
    /// "Fri", "Nov 12" — short label for a "when" chip.
    func shortLabel(today: Day) -> String {
        let offset = today.days(until: self)
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        if (2...6).contains(offset) { return date().formatted(.dateTime.weekday(.abbreviated)) }
        if year == today.year { return date().formatted(.dateTime.month(.abbreviated).day()) }
        return date().formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "3 days left", "Due today", "2 days ago".
    func deadlineLabel(today: Day) -> String {
        let offset = today.days(until: self)
        switch offset {
        case 0: return "Due today"
        case 1: return "1 day left"
        case 2...: return "\(offset) days left"
        case -1: return "1 day ago"
        default: return "\(-offset) days ago"
        }
    }
}

/// Minutes after midnight formatted as a local time, e.g. "9:30 AM".
func reminderLabel(_ minutes: Int) -> String {
    let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    return date.formatted(date: .omitted, time: .shortened)
}

// MARK: - Shared components

/// Things-style round-cornered checkbox. Canceled items show an ×.
struct CheckBox: View {
    var status: Status
    var tint: Color = .secondary
    var size: CGFloat = 16
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(status == .open ? tint.opacity(0.7) : Color.clear, lineWidth: 1.4)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .fill(status == .completed ? Color.accentColor : (status == .canceled ? Color.secondary.opacity(0.5) : Color.clear))
                    )
                if status != .open {
                    Image(systemName: status == .completed ? "checkmark" : "xmark")
                        .font(.system(size: size * 0.6, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status == .open ? "Complete" : "Mark as open")
    }
}

/// Things' project progress circle: a ring that fills like a pie.
struct ProgressPie: View {
    var progress: Double
    var tint: Color = Theme.project
    var size: CGFloat = 16
    var completed = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint, lineWidth: max(1.2, size * 0.09))
            if completed {
                Circle().fill(tint)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                PieSlice(fraction: progress)
                    .fill(tint)
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
    }
}

struct PieSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, fraction)), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct TagPill: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.tagBackground))
            .foregroundStyle(.secondary)
    }
}

/// Icon for a list in the sidebar or a header.
struct ListIcon: View {
    @Environment(AppModel.self) private var model
    var list: ListID
    var size: CGFloat = 16

    var body: some View {
        switch list {
        case .project(let id):
            let progress = model.store.snapshot.progress(of: id)
            ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: size * 0.95,
                        completed: model.store.project(id)?.status == .completed)
        default:
            Image(systemName: list.systemImage)
                .foregroundStyle(list.tint)
                .font(.system(size: size * 0.9))
                .frame(width: size, height: size)
        }
    }
}
