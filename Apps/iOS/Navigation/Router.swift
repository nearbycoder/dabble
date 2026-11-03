import DabbleKit
import Observation
import SwiftUI

/// The to-do shown in the detail card.
struct DetailTarget: Identifiable, Hashable {
    let id: UUID
    var isNew = false
}

/// Per-window navigation state. On iPhone `path` is the root stack; on iPad
/// it's the stack inside the detail column and `selection` drives the sidebar.
@MainActor
@Observable
final class Router {
    var path: [ListID] = []
    var selection: ListID? = .today
    var isCompact = true
    var detail: DetailTarget? {
        didSet { if let detail { lastDetail = detail } }
    }
    /// The most recently opened detail, for cleanup after the sheet closes.
    private(set) var lastDetail: DetailTarget?
    var showSettings = false
    var searchText = ""
    /// A project or area whose title field should grab focus when it appears.
    var focusTitle: UUID?
    /// Bumped whenever something is completed so the root can play a haptic.
    var completionTick = 0

    /// Jumps to a list from the top level (sidebar, URL, Quick Find).
    func show(_ list: ListID) {
        if isCompact {
            path = [list]
        } else {
            selection = list
            path = []
        }
    }

    /// Drills into a list from inside another list.
    func push(_ list: ListID) {
        guard path.last != list, isCompact || selection != list else { return }
        path.append(list)
    }

    /// Navigates away from a list that no longer exists (deleted or completed project).
    func leave(_ list: ListID) {
        if path.last == list {
            path.removeLast()
        } else if selection == list {
            selection = .today
        }
    }

    func open(_ id: UUID, isNew: Bool = false) {
        detail = DetailTarget(id: id, isNew: isNew)
    }

    func didComplete() {
        completionTick += 1
    }
}
