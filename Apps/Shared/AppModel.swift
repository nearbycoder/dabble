import DabbleKit
import Foundation
import Observation
import SwiftUI

/// Owns the store, the sync engine and reminders for the app's lifetime.
@MainActor
@Observable
final class AppModel {
    let store: DabbleStore
    let sync: SyncEngine
    let reminders: ReminderScheduler

    /// The day lists are computed for. Refreshed when the app becomes active
    /// and at midnight, so Today rolls over without a relaunch.
    private(set) var today = Day.today

    var logbookPolicy: LogbookPolicy {
        get { store.logbookPolicy }
        set {
            store.logbookPolicy = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "logbookPolicy")
        }
    }

    @ObservationIgnored private var midnightTask: Task<Void, Never>?

    init(directory: URL = DabbleStore.defaultDirectory) {
        store = DabbleStore(directory: directory)
        sync = SyncEngine(store: store, directory: directory)
        reminders = ReminderScheduler(store: store)
        if let raw = UserDefaults.standard.string(forKey: "logbookPolicy"), let policy = LogbookPolicy(rawValue: raw) {
            store.logbookPolicy = policy
        }
    }

    /// Call once when the first window appears.
    func launch() {
        if store.records.isEmpty && !UserDefaults.standard.bool(forKey: "seededWelcome") {
            WelcomeContent.install(in: store)
            UserDefaults.standard.set(true, forKey: "seededWelcome")
        }
        sync.start()
        reminders.start()
        scheduleMidnightRefresh()
        Task { _ = await ReminderScheduler.requestAuthorization() }
    }

    func becameActive() {
        today = .today
        sync.resume()
        scheduleMidnightRefresh()
    }

    func willResignActive() {
        store.saveNow()
        sync.flush()
    }

    var lists: Lists { store.lists(today: today) }

    private func scheduleMidnightRefresh() {
        midnightTask?.cancel()
        let tomorrow = Day.today.adding(days: 1).date()
        midnightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, tomorrow.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            self?.today = .today
            self?.scheduleMidnightRefresh()
        }
    }
}
