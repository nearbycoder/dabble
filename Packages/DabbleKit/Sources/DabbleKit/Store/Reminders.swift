import Foundation
import UserNotifications

/// Keeps local notifications in step with reminder times in the store.
///
/// Each device schedules its own notifications from its own copy of the data,
/// so a reminder set on the Mac fires on the iPhone once they've synced.
@MainActor
public final class ReminderScheduler {
    private let store: DabbleStore
    private var token: UUID?
    private var task: Swift.Task<Void, Never>?
    private static let prefix = "dabble.reminder."

    public init(store: DabbleStore) {
        self.store = store
    }

    public func start() {
        guard token == nil else { return }
        token = store.observe { [weak self] _ in self?.scheduleRefresh() }
        scheduleRefresh()
    }

    public static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private func scheduleRefresh() {
        task?.cancel()
        task = Swift.Task { [weak self] in
            try? await Swift.Task.sleep(for: .seconds(1))
            guard !Swift.Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Upcoming reminders, soonest first.
    public static func pending(in snapshot: Snapshot, now: Date = Date(), calendar: Calendar = .current) -> [(id: UUID, title: String, body: String, date: Date)] {
        var result: [(UUID, String, String, Date)] = []
        func consider<T: Schedulable>(_ item: T, body: String) {
            guard item.isOpen, !item.isTrashed, let minutes = item.reminder, let day = item.startDate else { return }
            let date = day.date(calendar: calendar).addingTimeInterval(TimeInterval(minutes * 60))
            if date > now { result.append((item.id, item.title, body, date)) }
        }
        for todo in snapshot.todos.values {
            consider(todo, body: todo.projectID.flatMap { snapshot.projects[$0]?.title } ?? (todo.notes.isEmpty ? "Reminder" : todo.notes))
        }
        for project in snapshot.projects.values { consider(project, body: "Project") }
        return result.sorted { $0.3 < $1.3 }.map { (id: $0.0, title: $0.1, body: $0.2, date: $0.3) }
    }

    func refresh() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        // iOS allows 64 pending notifications per app; keep the soonest.
        let wanted = Self.pending(in: store.snapshot).prefix(60)
        let existing = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier))
        for reminder in wanted {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.userInfo = ["id": reminder.id.uuidString]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            let request = UNNotificationRequest(
                identifier: Self.prefix + reminder.id.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            )
            try? await center.add(request)
        }
    }
}
