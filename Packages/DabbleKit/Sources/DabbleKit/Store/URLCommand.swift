import Foundation

/// The `dabble:///` URL scheme, modeled on Things' `things:///`.
///
///     dabble:///add?title=Buy%20milk&notes=…&when=today&deadline=2026-12-01&tags=Errands,Home&list=Groceries&checklist-items=Oat%0AAlmond
///     dabble:///add-project?title=Trip&area=Personal&to-dos=Book%20flight%0APack
///     dabble:///show?id=<uuid>   or   dabble:///show?id=today
///     dabble:///search?query=milk
public enum URLCommand: Equatable, Sendable {
    case show(ListID)
    case showItem(UUID)
    case search(String)
    case added(UUID)

    public enum Failure: Error, Equatable {
        case unsupported
        case missingParameter(String)
    }
}

public extension DabbleStore {
    /// Runs a `dabble:///` URL. Returns what the UI should show afterwards.
    func perform(_ url: URL, today: Day = .today) throws -> URLCommand {
        guard url.scheme == "dabble" else { throw URLCommand.Failure.unsupported }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let command = (url.host?.isEmpty == false ? url.host! : url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()

        switch command {
        case "add":
            let titles = (query["titles"]?.components(separatedBy: "\n") ?? [query["title"] ?? ""]).filter { !$0.isEmpty }
            guard !titles.isEmpty else { throw URLCommand.Failure.missingParameter("title") }
            var last: UUID?
            batch {
                for title in titles {
                    let list = resolveList(query["list"] ?? query["list-id"])
                    let heading = query["heading"].flatMap { name in
                        if case .project(let projectID)? = list {
                            return snapshot.headings(in: projectID).first { $0.title.caseInsensitiveCompare(name) == .orderedSame }?.id
                        }
                        return nil
                    }
                    let todo = addToDo(title, notes: query["notes"] ?? "", in: list ?? .inbox, heading: heading,
                                       when: query["when"].flatMap { When.parse($0, today: today) }, today: today)
                    applyCommon(query, to: todo.id, today: today)
                    for line in (query["checklist-items"] ?? "").components(separatedBy: "\n") where !line.isEmpty {
                        addChecklistItem(line, to: todo.id)
                    }
                    if query["completed"] == "true" { setStatus([todo.id], .completed, today: today) }
                    last = todo.id
                }
            }
            return query["reveal"] == "true" ? .showItem(last!) : .added(last!)

        case "add-project":
            guard let title = query["title"], !title.isEmpty else { throw URLCommand.Failure.missingParameter("title") }
            let areaID = query["area-id"].flatMap(UUID.init(uuidString:)) ?? query["area"].flatMap { name in
                snapshot.areaList.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }?.id
            }
            let project = batch { () -> Project in
                let project = addProject(title, area: areaID, when: query["when"].flatMap { When.parse($0, today: today) })
                update(Project.self, project.id) { $0.notes = query["notes"] ?? "" }
                applyCommon(query, to: project.id, today: today)
                for line in (query["to-dos"] ?? "").components(separatedBy: "\n") where !line.isEmpty {
                    addToDo(line, in: .project(project.id), today: today)
                }
                return project
            }
            return query["reveal"] == "true" ? .show(.project(project.id)) : .added(project.id)

        case "show":
            let target = query["id"] ?? query["query"] ?? ""
            if let id = UUID(uuidString: target) {
                if project(id) != nil { return .show(.project(id)) }
                if area(id) != nil { return .show(.area(id)) }
                if tag(id) != nil { return .show(.tag(id)) }
                return .showItem(id)
            }
            if let list = resolveList(target) { return .show(list) }
            throw URLCommand.Failure.missingParameter("id")

        case "search":
            return .search(query["query"] ?? "")

        default:
            throw URLCommand.Failure.unsupported
        }
    }

    private func applyCommon(_ query: [String: String], to id: UUID, today: Day) {
        if let raw = query["deadline"], let when = When.parse(raw, today: today) {
            switch when {
            case .date(let day): setDeadline([id], day)
            case .today, .evening: setDeadline([id], today)
            default: break
            }
        }
        if let names = query["tags"] {
            let tags = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { addTag($0).id }
            setTags(id, tags)
        }
    }

    /// Resolves a built-in list name, or a project/area by title or id.
    func resolveList(_ name: String?) -> ListID? {
        guard let name, !name.isEmpty else { return nil }
        switch name.lowercased() {
        case "inbox": return .inbox
        case "today": return .today
        case "upcoming": return .upcoming
        case "anytime": return .anytime
        case "someday": return .someday
        case "logbook": return .logbook
        case "trash": return .trash
        default: break
        }
        if let id = UUID(uuidString: name) {
            if project(id) != nil { return .project(id) }
            if area(id) != nil { return .area(id) }
        }
        let snapshot = snapshot
        if let project = snapshot.projects.values.first(where: { $0.isOpen && !$0.isTrashed && $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return .project(project.id)
        }
        if let area = snapshot.areaList.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return .area(area.id)
        }
        return nil
    }
}
