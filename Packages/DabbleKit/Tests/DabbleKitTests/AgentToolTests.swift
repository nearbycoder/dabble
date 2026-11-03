import XCTest
@testable import DabbleKit

@MainActor
final class AgentToolTests: XCTestCase {
    var store: DabbleStore!
    var box: AgentToolbox!

    override func setUp() async throws {
        store = DabbleStore(directory: nil)
        box = AgentToolbox(store: store)
    }

    private func id(_ value: JSONValue) -> String { value["id"]!.stringValue! }

    func testEveryToolHasAValidSchema() {
        XCTAssertGreaterThanOrEqual(AgentToolbox.tools.count, 20)
        var names = Set<String>()
        for tool in AgentToolbox.tools {
            XCTAssertTrue(names.insert(tool.name).inserted, "duplicate \(tool.name)")
            XCTAssertEqual(tool.inputSchema["type"], "object")
            XCTAssertFalse(tool.description.isEmpty)
            if let primary = tool.primary { XCTAssertNotNil(tool.inputSchema["properties"]?[primary], "\(tool.name) primary") }
            for required in tool.inputSchema["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(tool.inputSchema["properties"]?[required.stringValue!], "\(tool.name).\(required)")
            }
        }
        XCTAssertEqual(AgentToolbox.tool(named: "add")?.name, "add_todo")
        XCTAssertEqual(AgentToolbox.tool(named: "list-items")?.name, "list_items")
    }

    func testAddTodoWithEverything() throws {
        let project = try box.call("add_project", ["title": "Trip", "headings": ["Booking"], "area": nil])
        let todo = try box.call("add_todo", [
            "title": "Book flights", "notes": "Window seat", "list": "trip", "heading": "Booking",
            "when": "tomorrow", "deadline": "2026-12-01", "reminder": "9am", "tags": ["Travel", "Errands"],
            "checklist": ["Compare prices", "Pay"], "repeat": "every 2 weeks",
        ])
        XCTAssertEqual(todo["project"]?["id"], project["id"])
        XCTAssertEqual(todo["heading"]?["title"], "Booking")
        XCTAssertEqual(todo["when"], .string(Day.today.adding(days: 1).description))
        XCTAssertEqual(todo["deadline"], "2026-12-01")
        XCTAssertEqual(todo["reminder"], "09:00")
        XCTAssertEqual(todo["tags"], ["Travel", "Errands"])
        XCTAssertEqual(todo["checklist"]?.arrayValue?.count, 2)
        XCTAssertEqual(todo["repeat"], "Every 2 weeks")
        XCTAssertEqual(store.snapshot.tags.count, 2)
    }

    func testListsAndOverview() throws {
        _ = try box.call("add_todo", ["title": "Inbox thing"])
        _ = try box.call("add_todo", ["title": "Tonight", "when": "this evening"])
        let today = try box.call("list_items", ["list": "today"])
        XCTAssertEqual(today["sections"]?.arrayValue?.last?["section"], "This Evening")
        let inbox = try box.call("list", ["list": "inbox"])
        XCTAssertEqual(inbox["sections"]?.arrayValue?.first?["items"]?.arrayValue?.first?["title"], "Inbox thing")
        let overview = try box.call("overview")
        XCTAssertEqual(overview["counts"]?["inbox"], 1)
        XCTAssertEqual(overview["counts"]?["today"], 1)
    }

    func testUpdateCompleteMoveAndClear() throws {
        let area = try box.call("add_area", ["title": "Home"])
        let todo = try box.call("add_todo", ["title": "Fix sink", "deadline": "fri"])
        var updated = try box.call("update_item", ["id": todo["id"]!, "title": "Fix kitchen sink", "deadline": nil, "move_to": "Home", "add_tags": "Urgent", "append_notes": "Call plumber"])
        XCTAssertEqual(updated["title"], "Fix kitchen sink")
        XCTAssertNil(updated["deadline"])
        XCTAssertEqual(updated["area"]?["id"], area["id"])
        XCTAssertEqual(updated["when"], "anytime", "leaving the inbox makes it actionable")
        XCTAssertEqual(updated["notes"], "Call plumber")
        XCTAssertEqual(updated["tags"], ["Urgent"])

        _ = try box.call("set_status", ["ids": [todo["id"]!]])
        XCTAssertEqual(store.todo(UUID(uuidString: id(todo))!)?.status, .completed)
        updated = try box.call("set_status", ["ids": todo["id"]!, "status": "open"])
        XCTAssertEqual(updated["updated"]?.arrayValue?.first?["status"], "open")

        _ = try box.call("schedule", ["ids": [todo["id"]!], "when": "someday"])
        XCTAssertEqual(store.todo(UUID(uuidString: id(todo))!)?.start, .someday)
    }

    func testChecklistTrashAndSearch() throws {
        let todo = try box.call("add_todo", ["title": "Pack", "checklist": "Socks\nCharger"])
        let items = todo["checklist"]!.arrayValue!
        var edited = try box.call("edit_checklist", ["todo": todo["id"]!, "check": [items[0]["id"]!], "add": ["Passport"], "remove": [items[1]["id"]!]])
        XCTAssertEqual(edited["checklist"]?.arrayValue?.map { $0["title"]!.stringValue! }, ["Socks", "Passport"])
        XCTAssertEqual(edited["checklist"]?.arrayValue?.first?["done"], true)
        edited = try box.call("update_item", ["id": items[0]["id"]!, "done": false])
        XCTAssertEqual(edited["done"], false)

        XCTAssertEqual(try box.call("search", ["query": .string("passport")])["results"]?.arrayValue?.count, 1)
        _ = try box.call("trash", ["ids": [todo["id"]!]])
        XCTAssertEqual(try box.call("list_items", ["list": "trash"])["sections"]?.arrayValue?.first?["items"]?.arrayValue?.count, 1)
        XCTAssertThrowsError(try box.call("empty_trash", [:]))
        _ = try box.call("empty_trash", ["confirm": true])
        XCTAssertNil(store.todo(UUID(uuidString: id(todo))!))
    }

    func testHelpfulErrors() {
        XCTAssertThrowsError(try box.call("add_todo", [:])) { XCTAssertTrue("\($0.localizedDescription)".contains("title")) }
        XCTAssertThrowsError(try box.call("list_items", ["list": "Nowhere"]))
        XCTAssertThrowsError(try box.call("add_todo", ["title": "x", "when": "the twelfth of never"]))
        XCTAssertThrowsError(try box.call("get_item", ["id": .string(UUID().uuidString)]))
        XCTAssertThrowsError(try box.call("bogus"))
    }

    func testParsers() throws {
        XCTAssertEqual(AgentToolbox.parseTime("5:15 pm"), 17 * 60 + 15)
        XCTAssertEqual(AgentToolbox.parseTime("12am"), 0)
        XCTAssertEqual(AgentToolbox.parseTime("17:00"), 17 * 60)
        XCTAssertNil(AgentToolbox.parseTime("25:00"))
        let rule = try box.parseRepeat("every monday and thursday after completion")
        XCTAssertEqual(rule.weekdays, [2, 5])
        XCTAssertEqual(rule.mode, .afterCompletion)
        XCTAssertEqual(try box.parseRepeat("monthly").unit, .month)
    }

    func testJSONRoundTrip() throws {
        let value: JSONValue = ["a": [1, "two", true, nil], "b": ["c": 2.5]]
        XCTAssertEqual(try JSONValue.parse(value.encoded()), value)
    }

    func testEmbeddedSkillMatchesTheRepository() throws {
        let skill = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent/skills/dabble/SKILL.md")
        let onDisk = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertEqual(AgentSkill.markdown, onDisk.hasSuffix("\n") ? String(onDisk.dropLast()) : onDisk,
                       "Run scripts/embed-skill.sh after editing SKILL.md")
        XCTAssertTrue(AgentSkill.markdown.hasPrefix("---\nname: dabble\n"))
    }
}
