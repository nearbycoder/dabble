import AppKit
import DabbleKit
import SwiftUI

// MARK: - Colors

extension NSAppearance {
    nonisolated var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    /// The content area behind lists: white in light mode, near-black in dark.
    static let listBackground = Color(nsColor: NSColor(name: "dabble.listBackground") { appearance in
        appearance.isDark ? NSColor(white: 0.125, alpha: 1) : NSColor.white
    })
    /// The expanded to-do card.
    static let cardBackground = Color(nsColor: NSColor(name: "dabble.cardBackground") { appearance in
        appearance.isDark ? NSColor(white: 0.18, alpha: 1) : NSColor.white
    })
    static let hairline = Color.primary.opacity(0.09)
    static let rowSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let rowSelectionFocused = Color(nsColor: .selectedContentBackgroundColor).opacity(0.3)
}

// MARK: - Drag & drop

/// To-dos and projects are dragged as a `dabble:///show` link, so dropping one
/// in another app gives a link back to it, like Things does.
enum DragPayload {
    nonisolated static func url(_ ids: [UUID]) -> URL {
        var components = URLComponents()
        components.scheme = "dabble"
        components.host = ""
        components.path = "/show"
        components.queryItems = [
            URLQueryItem(name: "id", value: ids.first?.uuidString ?? ""),
            URLQueryItem(name: "items", value: ids.map(\.uuidString).joined(separator: ",")),
        ]
        return components.url!
    }

    nonisolated static func ids(from url: URL) -> [UUID] {
        guard url.scheme == "dabble" else { return [] }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let raw = items.first { $0.name == "items" }?.value ?? items.first { $0.name == "id" }?.value ?? ""
        return raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    static func provider(_ ids: [UUID]) -> NSItemProvider {
        NSItemProvider(object: url(ids) as NSURL)
    }

    /// Reads the dragged ids out of a drop.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([UUID]) -> Void) {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            let ids = url.map { DragPayload.ids(from: $0) } ?? []
            Task { @MainActor in
                if !ids.isEmpty { completion(ids) }
            }
        }
    }
}

// MARK: - Model helpers

extension DabbleStore {
    func status(of id: UUID) -> Status {
        todo(id)?.status ?? project(id)?.status ?? .open
    }

    /// Copies a to-do (and its checklist) right after the original.
    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let todo = todo(id) else { return nil }
        var values = todo.values
        values[Key.createdAt] = nil
        values[Key.repeatSeries] = nil
        let copy = ToDo(id: UUID(), values: values)
        batch {
            save(copy)
            for item in snapshot.checklists[id] ?? [] {
                var newItem = ChecklistItem(title: item.title, todoID: copy.id)
                newItem.isDone = item.isDone
                newItem.index = item.index
                save(newItem)
            }
        }
        return copy.id
    }

    /// Turns a heading into its own project, taking its to-dos along.
    func convertHeadingToProject(_ headingID: UUID) -> Project? {
        guard let heading = heading(headingID), let projectID = heading.projectID else { return nil }
        let areaID = project(projectID)?.areaID
        return batch {
            let project = addProject(heading.title.nonEmpty ?? "New Project", area: areaID)
            let todos = snapshot.todos.values.filter { $0.headingID == headingID }.map(\.id)
            move(todos, to: .project(project.id))
            delete(headingID)
            return project
        }
    }
}

extension Lists {
    /// The project or area an item belongs to, shown under its title.
    func subtitle(for item: Item) -> String? {
        switch item {
        case .todo(let todo):
            if let projectID = todo.projectID, let project = snapshot.projects[projectID] {
                return project.title.nonEmpty ?? "New Project"
            }
            if let areaID = todo.areaID { return snapshot.areas[areaID]?.title.nonEmpty ?? "New Area" }
            return nil
        case .project(let project):
            return project.areaID.flatMap { snapshot.areas[$0]?.title }
        default:
            return nil
        }
    }

    /// Which list a to-do shows up in, for revealing it.
    func home(of todo: ToDo) -> ListID {
        if todo.isTrashed { return .trash }
        if let projectID = todo.projectID, snapshot.projects[projectID] != nil { return .project(projectID) }
        if let areaID = todo.areaID, snapshot.areas[areaID] != nil { return .area(areaID) }
        if !todo.isOpen { return .logbook }
        if isInInbox(todo) { return .inbox }
        if isInToday(todo) { return .today }
        if let date = todo.startDate, date > today { return .upcoming }
        if todo.start == .someday { return .someday }
        return .anytime
    }
}

extension Item {
    var status: Status {
        switch self {
        case .todo(let todo): todo.status
        case .project(let project): project.status
        default: .open
        }
    }

    var isTrashed: Bool {
        switch self {
        case .todo(let x): x.isTrashed
        case .project(let x): x.isTrashed
        case .area(let x): x.isTrashed
        default: false
        }
    }
}

extension When {
    /// The When an item currently has, for highlighting in the picker.
    init?<T: Schedulable>(of item: T, today: Day) {
        if item.start == .someday && item.startDate == nil { self = .someday; return }
        guard let date = item.startDate else { return nil }
        if date <= today { self = item.isEvening ? .evening : .today; return }
        self = .date(date)
    }
}

extension View {
    /// A little rounded "chip" label used for dates and counts.
    func chipStyle(_ tint: Color = .secondary, filled: Bool = true) -> some View {
        self
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(filled ? Theme.tagBackground : .clear))
    }
}

/// Local IPv4 addresses, shown so people can pair or sync over a VPN.
func localIPAddresses() -> [String] {
    var result: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = entry.pointee
        guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(interface.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            if !ip.hasPrefix("169.254") { result.append(ip) }
        }
    }
    return Array(Set(result)).sorted()
}
