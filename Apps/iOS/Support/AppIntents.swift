import AppIntents
import DabbleKit
import Foundation

/// "Add a to-do in Dabble" — adds to the Inbox without opening the app.
/// Runs in the app's process and goes through the shared model, so it never
/// races a second copy of the store.
struct AddToDoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add To-Do"
    static let description = IntentDescription("Adds a to-do to your Dabble Inbox.")
    static let openAppWhenRun = false

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "When", description: "For example “today”, “tomorrow” or “fri”.")
    var when: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Dabble") {
            \.$notes
            \.$when
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw $title.needsValueError("What's the to-do?")
        }
        let model = AppContainer.model
        let schedule = when.flatMap { DabbleKit.When.parse($0, today: model.today) }
        model.store.addToDo(trimmed, notes: notes ?? "", in: .inbox, when: schedule, today: model.today)
        model.store.saveNow()
        let place = schedule.map { $0 == DabbleKit.When.inbox ? "your Inbox" : $0.label } ?? "your Inbox"
        return .result(dialog: "Added “\(trimmed)” to \(place).")
    }
}

struct DabbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToDoIntent(),
            phrases: [
                "Add a to-do in \(.applicationName)",
                "New \(.applicationName) to-do",
                "Add to \(.applicationName)",
            ],
            shortTitle: "Add To-Do",
            systemImageName: "plus.circle"
        )
    }
}
