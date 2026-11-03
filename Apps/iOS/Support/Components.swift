import DabbleKit
import SwiftUI

// MARK: - Editable text

/// A text field that edits a stored value without writing on every keystroke.
/// Commits after a short pause, on return, when focus leaves, and on disappear.
struct EditableText: View {
    var placeholder: String
    var value: String
    var axis: Axis = .horizontal
    var autoFocus = false
    var onCommit: (String) -> Void
    var onSubmit: ((String) -> Void)? = nil

    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, axis: axis)
            .focused($focused)
            .onAppear {
                if !loaded {
                    draft = value
                    loaded = true
                }
            }
            .task {
                guard autoFocus else { return }
                try? await Task.sleep(for: .milliseconds(450))
                focused = true
            }
            .onChange(of: value) { _, newValue in
                if !focused { draft = newValue }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit {
                commit()
                onSubmit?(draft)
            }
            .onDisappear(perform: commit)
            .task(id: draft) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                commit()
            }
    }

    private func commit() {
        guard loaded, draft != value else { return }
        onCommit(draft)
    }
}

// MARK: - Flow layout

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - Small views

/// A capsule label used for "when" and deadline chips.
struct Chip: View {
    var title: String
    var systemImage: String
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
            .foregroundStyle(filled ? .white : tint)
    }
}

/// Red pill showing the number of due items, like Things' Today badge.
struct CountBadge: View {
    var count: Int
    var tint: Color = Theme.deadline

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint))
            .foregroundStyle(.white)
    }
}

// MARK: - ListID helpers

extension ListID {
    var isBuiltIn: Bool {
        switch self {
        case .project, .area, .tag: false
        default: true
        }
    }

    var projectID: UUID? {
        if case .project(let id) = self { return id }
        return nil
    }

    var areaID: UUID? {
        if case .area(let id) = self { return id }
        return nil
    }

    /// Whether the magic plus button makes sense here.
    var acceptsNewItems: Bool {
        self != .logbook && self != .trash
    }

    /// Lists whose rows can be dragged into a new order.
    var supportsReordering: Bool {
        switch self {
        case .logbook, .trash: false
        default: true
        }
    }

    /// Lists where each row says which project or area it belongs to.
    var showsContainer: Bool {
        switch self {
        case .today, .upcoming, .logbook, .trash, .tag, .inbox: true
        default: false
        }
    }
}

// MARK: - Store helpers

extension DabbleStore {
    /// Copies a to-do and its checklist, placing the copy right after it.
    @discardableResult
    func duplicateToDo(_ id: UUID) -> ToDo? {
        guard let original = todo(id) else { return nil }
        return batch {
            var copy = ToDo(id: UUID(), values: original.values)
            copy.index = original.index + 0.001
            copy.todayIndex = original.todayIndex + 0.001
            if copy.repeatRule != nil { copy.repeatSeries = copy.id }
            save(copy)
            for item in snapshot.checklists[id] ?? [] {
                var newItem = ChecklistItem(title: item.title, todoID: copy.id)
                newItem.index = item.index
                newItem.isDone = item.isDone
                save(newItem)
            }
            return copy
        }
    }

    /// Plain-text rendering of a list, for sharing.
    func shareText(for list: ListID, lists: Lists) -> String {
        var lines = [list.title(in: self)]
        if case .project(let id) = list, let notes = project(id)?.notes, !notes.isEmpty {
            lines.append(notes)
        }
        for group in lists.items(for: list) {
            switch group.header {
            case .heading(let heading): lines.append("\n\(heading.title)")
            case .later: lines.append("\nLater")
            case .evening: lines.append("\nThis Evening")
            default: break
            }
            for item in group.items {
                switch item {
                case .todo(let todo): lines.append("\(todo.isOpen ? "- [ ]" : "- [x]") \(todo.title)")
                case .project(let project): lines.append("• \(project.title)")
                default: break
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func title(of item: Item) -> String {
        switch item {
        case .todo(let todo): todo.title.nonEmpty ?? "New To-Do"
        case .project(let project): project.title.nonEmpty ?? "New Project"
        case .area(let area): area.title.nonEmpty ?? "New Area"
        default: item.title
        }
    }
}

// MARK: - When helpers

extension Schedulable {
    /// What a "when" chip should say about this item, if anything.
    func whenDescription(today: Day) -> (title: String, systemImage: String, tint: Color)? {
        if let date = startDate {
            if date <= today {
                return isEvening ? ("This Evening", "moon.fill", Theme.evening) : ("Today", "star.fill", Theme.today)
            }
            return (date.relativeLabel(today: today), "calendar", Theme.upcoming)
        }
        if start == .someday { return ("Someday", "archivebox.fill", Theme.someday) }
        return nil
    }
}

extension Date {
    /// "just now", "2m ago", "3h ago", "4d ago".
    var shortAgo: String {
        let seconds = max(0, Int(Date().timeIntervalSince(self)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}

// MARK: - Network

enum NetworkInfo {
    /// This device's IPv4 addresses on Wi-Fi, Ethernet and VPN interfaces.
    static func localAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !ip.hasPrefix("169.254"), !result.contains(ip) { result.append(ip) }
        }
        return result
    }

    /// Splits "host:port" (or "[v6]:port").
    static func parse(_ address: String) -> (host: String, port: UInt16)? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":"), let port = UInt16(trimmed[trimmed.index(after: colon)...]), port > 0 else { return nil }
        let host = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, port)
    }
}

extension SyncEngine.Peer {
    var systemImage: String {
        switch platform {
        case "macOS": "laptopcomputer"
        case "iPadOS": "ipad"
        case "iOS": "iphone"
        default: "desktopcomputer"
        }
    }
}
