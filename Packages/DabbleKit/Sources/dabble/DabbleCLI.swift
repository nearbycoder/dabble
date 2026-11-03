import DabbleKit
import Foundation

/// `dabble`: Dabble for agents and terminals.
///
/// The CLI is its own Dabble device. It keeps a replica in ~/.dabble, joins the
/// user's sync group, and syncs with their Mac, iPhone and iPad (or sync server)
/// like any other device. While `dabble mcp` is running it owns the replica and
/// other `dabble` invocations forward their commands to it.
@main
struct DabbleCLI {
    static let version = "1.2.0"

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let options = Options.extract(from: &arguments)
        let code = await MainActor.run { () -> Swift.Task<Int32, Never> in
            Swift.Task { @MainActor in await run(arguments, options) }
        }.value
        exit(code)
    }

    @MainActor
    static func run(_ arguments: [String], _ options: Options) async -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 0
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "help", "-h", "--help":
                if let topic = rest.first, let tool = AgentToolbox.tool(named: topic) {
                    print(Render.help(for: tool))
                } else {
                    print(usage)
                }
            case "version", "--version", "-v":
                print("dabble \(version)")
            case "tools":
                print(options.json ? Render.toolsJSON() : Render.toolList())
            case "mcp":
                return await MCPServer(options: options).run()
            case "join":
                return try await Setup.join(rest, options)
            case "pair":
                return try await Setup.pair(rest, options)
            case "leave":
                return try await Setup.leave(options)
            case "key":
                return try await Setup.key(options)
            case "name":
                return try await Setup.rename(rest, options)
            case "server":
                return try await Setup.server(rest, options)
            case "skill":
                return try Setup.skill(rest)
            case "call":
                guard rest.count >= 1 else { throw UsageError("Usage: dabble call <tool> '<json arguments>'") }
                let json = rest.count > 1 ? try JSONValue.parse(rest[1]) : [:]
                guard let object = json.objectValue else { throw UsageError("Arguments must be a JSON object.") }
                return try await runTool(rest[0], object, options)
            default:
                let (tool, preset) = Self.resolve(command)
                guard let tool else { throw UsageError("Unknown command “\(command)”. Run `dabble help` or `dabble tools`.") }
                var parsed = try ArgumentParser.parse(rest, for: tool)
                parsed.merge(preset) { current, _ in current }
                return try await runTool(tool.name, parsed, options)
            }
            return 0
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("\(error.message)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("dabble: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// CLI-only shortcuts that preset some arguments.
    static func resolve(_ command: String) -> (AgentTool?, [String: JSONValue]) {
        switch command {
        case "complete", "done": (AgentToolbox.tool(named: "set_status"), ["status": "completed"])
        case "cancel": (AgentToolbox.tool(named: "set_status"), ["status": "canceled"])
        case "reopen": (AgentToolbox.tool(named: "set_status"), ["status": "open"])
        case "today": (AgentToolbox.tool(named: "list_items"), ["list": "today"])
        case "inbox": (AgentToolbox.tool(named: "list_items"), ["list": "inbox"])
        case "upcoming": (AgentToolbox.tool(named: "list_items"), ["list": "upcoming"])
        case "anytime": (AgentToolbox.tool(named: "list_items"), ["list": "anytime"])
        case "someday": (AgentToolbox.tool(named: "list_items"), ["list": "someday"])
        case "logbook": (AgentToolbox.tool(named: "list_items"), ["list": "logbook"])
        default: (AgentToolbox.tool(named: command), [:])
        }
    }

    /// Runs one tool: through a running `dabble mcp` if there is one, otherwise
    /// against the replica directly (syncing before and after).
    @MainActor
    static func runTool(_ name: String, _ arguments: [String: JSONValue], _ options: Options) async throws -> Int32 {
        guard let tool = AgentToolbox.tool(named: name) else { throw UsageError("Unknown tool “\(name)”. Run `dabble tools`.") }
        let result: JSONValue
        if let forwarded = try await ControlClient.call(home: options.home, tool: tool.name, arguments: arguments) {
            result = forwarded
        } else {
            let replica = try await Replica.open(home: options.home)
            defer { replica.close() }
            try replica.requireJoined(allowLocal: options.local || tool.name == "sync_status")
            let heard = options.noSync ? false : await replica.catchUp(timeout: options.wait)
            result = try replica.box.call(tool.name, arguments)
            if !tool.readOnly {
                await replica.flush()
                if replica.sync.hasGroup && !heard && !options.noSync {
                    FileHandle.standardError.write(Data("Note: none of your devices were reachable, so this is saved on this computer and will sync next time dabble runs while one of them is.\n".utf8))
                }
            }
        }
        print(options.json ? result.encoded(pretty: true) : Render.result(of: tool.name, result))
        return 0
    }

    static let usage = """
    dabble \(version): your Dabble to-dos from the terminal, scripts and AI agents.

    Setup:
      dabble join <sync key> [--server URL]   Join your devices (copy the key from Dabble → Settings → Agents)
      dabble pair [--address host:port]        Or pair by comparing a code with a nearby device
      dabble status                            Connection and sync status
      dabble name "Work laptop agent"          Rename this device
      dabble server <url|off>                  Use (or stop using) a sync server
      dabble key                               Print the sync key (to join other devices to this one)
      dabble leave                             Leave the sync group
      dabble skill [install [--dir DIR]]       Print or install the Agent Skill (default ~/.claude/skills)
      dabble mcp                               Run the MCP server on stdin/stdout

    To-dos:
      dabble today | inbox | upcoming | anytime | someday | logbook
      dabble list <list, project, area or tag> [--tag T]
      dabble search <words>
      dabble show <id>
      dabble add "Title" [--list L] [--when W] [--deadline D] [--tags a,b] [--notes N] [--checklist "a\\nb"]
      dabble update <id> [--title T] [--when W] [--deadline D|null] [--move-to P] [--add-tags a] ...
      dabble complete|cancel|reopen <id> [<id> ...]
      dabble schedule <id>[,<id>] --when today
      dabble move <id> --to "Project" [--heading H]
      dabble trash|restore <id> ...
      dabble <tool> [args]                      Any tool; see `dabble tools` and `dabble help <tool>`
      dabble call <tool> '<json>'               Exact JSON arguments

    Options:
      --json          Print JSON (recommended for scripts and agents)
      --wait <secs>   How long to wait for your devices before acting (default 4)
      --no-sync       Don't sync; use this computer's copy as is
      --local         Allow use without joining a sync group (data stays on this computer)
      --home <dir>    Where the replica lives (default ~/.dabble, or $DABBLE_HOME)

    Ids can be shortened to their first 8 characters.
    """
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct Options {
    var json = false
    var noSync = false
    var local = false
    var wait: Duration = .seconds(4)
    var home: URL

    /// Pulls global flags out of the argument list, wherever they appear.
    static func extract(from arguments: inout [String]) -> Options {
        let environment = ProcessInfo.processInfo.environment
        let defaultHome = environment["DABBLE_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dabble", isDirectory: true)
        var options = Options(home: defaultHome)
        if environment["DABBLE_LOCAL"] == "1" { options.local = true }
        var kept: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": options.json = true
            case "--no-sync", "--offline": options.noSync = true
            case "--local": options.local = true
            case "--wait":
                index += 1
                if index < arguments.count, let seconds = Double(arguments[index]) { options.wait = .milliseconds(Int(seconds * 1000)) }
            case "--home":
                index += 1
                if index < arguments.count { options.home = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath) }
            default:
                kept.append(argument)
            }
            index += 1
        }
        arguments = kept
        return options
    }
}

/// Turns `"Title" --when tomorrow --tags a,b --done` into tool arguments.
enum ArgumentParser {
    static func parse(_ arguments: [String], for tool: AgentTool) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        var positional: [String] = []
        let properties = tool.inputSchema["properties"]?.objectValue ?? [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                var key = String(argument.dropFirst(2))
                var value: String?
                if let equals = key.firstIndex(of: "=") {
                    value = String(key[key.index(after: equals)...])
                    key = String(key[..<equals])
                }
                key = key.replacingOccurrences(of: "-", with: "_")
                guard properties[key] != nil else {
                    throw UsageError("\(tool.name) has no option --\(key.replacingOccurrences(of: "_", with: "-")). Run `dabble help \(tool.name)`.")
                }
                if value == nil {
                    let isBool = properties[key]?["type"] == "boolean"
                    if !isBool, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                        index += 1
                        value = arguments[index]
                    } else {
                        value = "true"
                    }
                }
                result[key] = convert(value!, schema: properties[key]!)
            } else {
                positional.append(argument)
            }
            index += 1
        }
        if !positional.isEmpty {
            guard let primary = tool.primary else { throw UsageError("\(tool.name) doesn't take a bare argument. Run `dabble help \(tool.name)`.") }
            if result[primary] == nil {
                let schema = properties[primary]!
                result[primary] = schema["type"] == "array"
                    ? .array(positional.flatMap { $0.split(separator: ",").map { .string(String($0)) } })
                    : convert(positional.joined(separator: " "), schema: schema)
            }
        }
        return result
    }

    static func convert(_ raw: String, schema: JSONValue) -> JSONValue {
        let value = raw.replacingOccurrences(of: "\\n", with: "\n")
        if value == "null" { return .null }
        if value.hasPrefix("{") || value.hasPrefix("["), let json = try? JSONValue.parse(value) { return json }
        switch schema["type"] {
        case "boolean": return .bool(["true", "yes", "1", "on"].contains(value.lowercased()))
        case "integer": return Int(value).map { .number(Double($0)) } ?? .string(value)
        default: return .string(value)
        }
    }
}
