import DabbleKit
import Foundation

/// Human-readable output. Agents should pass --json instead.
enum Render {
    /// Styling only when printing to a terminal.
    static let styled = isatty(STDOUT_FILENO) != 0

    static func bold(_ text: String) -> String { styled ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
    static func dim(_ text: String) -> String { styled ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
    static func result(of tool: String, _ value: JSONValue) -> String {
        switch tool {
        case "list_items": return list(value)
        case "search": return items(value["results"]?.arrayValue ?? [], indent: "").nonEmpty ?? "Nothing found."
        case "overview": return overview(value)
        case "get_item": return detail(value)
        case "set_status", "schedule", "move":
            return items(value["updated"]?.arrayValue ?? [], indent: "")
        default:
            if value["type"] == "todo" || value["type"] == "project" { return detail(value) }
            return value.encoded(pretty: true)
        }
    }

    static func shortID(_ item: JSONValue) -> String {
        String((item["id"]?.stringValue ?? "").prefix(8))
    }

    static func line(_ item: JSONValue) -> String {
        let box: String
        switch (item["type"]?.stringValue, item["status"]?.stringValue) {
        case ("project", "completed"): box = "(✓)"
        case ("project", _): box = "( )"
        case ("area", _): box = "[■]"
        case ("tag", _): box = " # "
        case (_, "completed"): box = "[✓]"
        case (_, "canceled"): box = "[×]"
        default: box = "[ ]"
        }
        var parts = ["\(box) \(item["title"]?.stringValue ?? "")"]
        if let when = item["when"]?.stringValue, !["anytime", "inbox"].contains(when) { parts.append("· \(when)") }
        if let deadline = item["deadline"]?.stringValue { parts.append("⚑ \(deadline)") }
        if let checklist = item["checklist"]?.stringValue { parts.append("☑ \(checklist)") }
        if let progress = item["progress"]?.stringValue { parts.append("\(progress) done") }
        if let tags = item["tags"]?.arrayValue, !tags.isEmpty { parts.append(tags.compactMap(\.stringValue).map { "#\($0)" }.joined(separator: " ")) }
        if let project = item["project"]?["title"]?.stringValue { parts.append("— \(project)") }
        else if let area = item["area"]?["title"]?.stringValue, item["type"] == "todo" { parts.append("— \(area)") }
        return parts.joined(separator: "  ") + "   \(dim(shortID(item)))"
    }

    static func items(_ list: [JSONValue], indent: String) -> String {
        list.map { indent + line($0) }.joined(separator: "\n")
    }

    static func list(_ value: JSONValue) -> String {
        var output = [bold(value["list"]?.stringValue ?? "")]
        let sections = value["sections"]?.arrayValue ?? []
        if sections.allSatisfy({ ($0["items"]?.arrayValue ?? []).isEmpty }) { output.append("  (empty)") }
        for section in sections {
            if let title = section["section"]?.stringValue { output.append("\n  " + bold(title)) }
            let entries = section["items"]?.arrayValue ?? []
            if !entries.isEmpty { output.append(items(entries, indent: "  ")) }
        }
        if let logged = value["logged"]?.arrayValue, !logged.isEmpty {
            output.append("\n  \(bold("Logged"))")
            output.append(items(logged, indent: "  "))
        }
        return output.joined(separator: "\n")
    }

    static func overview(_ value: JSONValue) -> String {
        var output: [String] = []
        let counts = value["counts"]
        output.append("Inbox \(counts?["inbox"]?.encoded() ?? "0") · Today \(counts?["today"]?.encoded() ?? "0") · due \(counts?["due_or_overdue"]?.encoded() ?? "0")")
        func projects(_ list: JSONValue?) -> [String] {
            (list?.arrayValue ?? []).map { "    ( ) \($0["title"]?.stringValue ?? "")  \($0["open_todos"]?.encoded() ?? "0") open   \(dim(shortID($0)))" }
        }
        let loose = projects(value["projects_without_area"])
        if !loose.isEmpty { output.append("\nProjects"); output += loose }
        for area in value["areas"]?.arrayValue ?? [] {
            output.append("\n" + bold(area["title"]?.stringValue ?? "") + "   " + dim(shortID(area)))
            output += projects(area["projects"])
        }
        let tags = (value["tags"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
        if !tags.isEmpty { output.append("\nTags: " + tags.map { "#\($0)" }.joined(separator: " ")) }
        if let sync = value["sync"], sync["joined"] == false { output.append("\n⚠︎ Not connected to your devices. Run `dabble join <sync key>`.") }
        return output.joined(separator: "\n")
    }

    static func detail(_ value: JSONValue) -> String {
        var output = [line(value)]
        for key in ["when", "deadline", "reminder", "repeat", "status"] {
            if let text = value[key]?.stringValue { output.append("  \(key): \(text)") }
        }
        if let notes = value["notes"]?.stringValue, !notes.isEmpty {
            output.append("")
            output += notes.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }
        }
        if let checklist = value["checklist"]?.arrayValue, !checklist.isEmpty {
            output.append("")
            for item in checklist {
                output.append("  \(item["done"] == true ? "[✓]" : "[ ]") \(item["title"]?.stringValue ?? "")   \(dim(shortID(item)))")
            }
        }
        if let sections = value["sections"]?.arrayValue {
            for section in sections {
                if let title = section["section"]?.stringValue { output.append("\n  " + bold(title)) } else { output.append("") }
                output.append(items(section["items"]?.arrayValue ?? [], indent: "  "))
            }
        }
        output.append("  " + dim("id: \(value["id"]?.stringValue ?? "")"))
        return output.joined(separator: "\n")
    }

    static func toolList() -> String {
        var lines = ["Tools (run `dabble help <tool>` for its options):", ""]
        for tool in AgentToolbox.tools {
            let summary = tool.description.split(separator: ".").first.map(String.init) ?? tool.description
            lines.append("  " + tool.name.padding(toLength: 20, withPad: " ", startingAt: 0) + summary)
        }
        return lines.joined(separator: "\n")
    }

    static func toolsJSON() -> String {
        JSONValue.array(AgentToolbox.tools.map(MCPServer.describe)).encoded(pretty: true)
    }

    static func help(for tool: AgentTool) -> String {
        var lines = ["dabble \(tool.name.replacingOccurrences(of: "_", with: "-"))\(tool.primary.map { " <\($0)>" } ?? "") [options]", "", tool.description, ""]
        let required = Set((tool.inputSchema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        for (name, schema) in (tool.inputSchema["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            let flag = "--" + name.replacingOccurrences(of: "_", with: "-")
            lines.append("  " + (flag + (required.contains(name) ? " (required)" : "")).padding(toLength: 28, withPad: " ", startingAt: 0) + (schema["description"]?.stringValue ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
