import XCTest
@testable import DabbleKit

@MainActor
final class StoreTests: XCTestCase {
    let today = Day(year: 2026, month: 11, day: 3)

    func testRecordMergeIsCommutativeAndIdempotent() {
        let id = UUID()
        var a = Record(id: id, kind: .todo, fields: [
            "title": Field(.string("A"), HLC(wall: 2, counter: 0, node: "a")),
            "notes": Field(.string("old"), HLC(wall: 1, counter: 0, node: "a")),
        ])
        let b = Record(id: id, kind: .todo, fields: [
            "title": Field(.string("B"), HLC(wall: 1, counter: 5, node: "b")),
            "notes": Field(.string("new"), HLC(wall: 3, counter: 0, node: "b")),
        ])
        var b2 = b
        b2.merge(a)
        a.merge(b)
        XCTAssertEqual(a.fields, b2.fields)
        XCTAssertEqual(a.values["title"], .string("A"))
        XCTAssertEqual(a.values["notes"], .string("new"))
        XCTAssertFalse(a.merge(b))
    }

    func testConcurrentEditsConvergeAcrossStores() {
        let one = DabbleStore(directory: nil, deviceID: "one")
        let two = DabbleStore(directory: nil, deviceID: "two")
        let todo = one.addToDo("Buy milk")
        two.merge(one.changes(since: 0))

        one.update(ToDo.self, todo.id) { $0.title = "Buy oat milk" }
        two.update(ToDo.self, todo.id) { $0.notes = "2 cartons" }

        two.merge(one.changes(since: 0))
        one.merge(two.changes(since: 0))

        XCTAssertEqual(one.todo(todo.id)?.title, "Buy oat milk")
        XCTAssertEqual(one.todo(todo.id)?.notes, "2 cartons")
        XCTAssertEqual(one.todo(todo.id)?.values, two.todo(todo.id)?.values)
    }

    func testListsFollowThingsSemantics() {
        let store = DabbleStore(directory: nil)
        let inbox = store.addToDo("Inbox item")
        let todayItem = store.addToDo("Today item", in: .today, today: today)
        let evening = store.addToDo("Evening item", when: .evening, today: today)
        let later = store.addToDo("Someday item", in: .someday)
        let scheduled = store.addToDo("Scheduled", when: .date(today.adding(days: 3)), today: today)
        let due = store.addToDo("Due", in: .anytime)
        store.setDeadline([due.id], today)

        let lists = store.lists(today: today)
        XCTAssertEqual(lists.inbox().flatMap(\.items).map(\.id), [inbox.id])

        let todayGroups = lists.todayList()
        XCTAssertEqual(Set(todayGroups[0].items.map(\.id)), [todayItem.id, due.id])
        XCTAssertEqual(todayGroups.last?.header, .evening)
        XCTAssertEqual(todayGroups.last?.items.map(\.id), [evening.id])

        XCTAssertEqual(lists.upcoming().first?.header, .day(today.adding(days: 3)))
        XCTAssertEqual(lists.upcoming().first?.items.map(\.id), [scheduled.id])
        XCTAssertEqual(lists.someday().flatMap(\.items).map(\.id), [later.id])

        let anytime = Set(lists.anytime().flatMap(\.items).map(\.id))
        XCTAssertTrue(anytime.isSuperset(of: [todayItem.id, evening.id, due.id]))
        XCTAssertFalse(anytime.contains(scheduled.id))
        XCTAssertFalse(anytime.contains(inbox.id))
    }

    func testProjectsGroupHeadingsAndCompletion() {
        let store = DabbleStore(directory: nil)
        let area = store.addArea("Work")
        let project = store.addProject("Launch", area: area.id)
        let heading = store.addHeading("Marketing", in: project.id)
        let a = store.addToDo("Write spec", in: .project(project.id))
        let b = store.addToDo("Tweet", in: .project(project.id), heading: heading.id)

        let groups = store.lists(today: today).project(project.id)
        XCTAssertEqual(groups[0].items.map(\.id), [a.id])
        guard case .heading(let shown) = groups[1].header else { return XCTFail("expected heading") }
        XCTAssertEqual(shown.id, heading.id)
        XCTAssertEqual(groups[1].items.map(\.id), [b.id])

        store.setStatus([project.id], .completed)
        XCTAssertEqual(store.todo(a.id)?.status, .completed)
        XCTAssertEqual(store.todo(b.id)?.status, .completed)
        store.logCompleted()
        XCTAssertEqual(Set(store.lists(today: today).logbook().flatMap(\.items).map(\.id)), [project.id, a.id, b.id])
    }

    func testTrashCascadesAndEmptyTrashTombstones() {
        let store = DabbleStore(directory: nil)
        let project = store.addProject("Old")
        let todo = store.addToDo("Inside", in: .project(project.id))
        store.trash([project.id])
        XCTAssertTrue(store.todo(todo.id)!.isTrashed)
        XCTAssertEqual(store.lists(today: today).trash().flatMap(\.items).map(\.id), [project.id])

        store.restore([project.id])
        XCTAssertFalse(store.todo(todo.id)!.isTrashed)

        store.trash([project.id])
        store.emptyTrash()
        XCTAssertNil(store.todo(todo.id))
        XCTAssertNil(store.project(project.id))
        XCTAssertEqual(store.records[todo.id]?.values.bool(Key.purged), true)
    }

    func testRepeatingToDoSpawnsDeterministicNextInstance() {
        let one = DabbleStore(directory: nil, deviceID: "one")
        let two = DabbleStore(directory: nil, deviceID: "two")
        let todo = one.addToDo("Water plants", when: .today, today: today)
        one.setRepeat(todo.id, RepeatRule(unit: .week), today: today)
        one.addChecklistItem("Ferns", to: todo.id)
        two.merge(one.changes(since: 0))

        // Both devices complete the same instance while offline.
        one.setStatus([todo.id], .completed, today: today)
        two.setStatus([todo.id], .completed, today: today)
        one.merge(two.changes(since: 0))

        let next = one.snapshot.todos.values.filter { $0.isOpen && $0.title == "Water plants" }
        XCTAssertEqual(next.count, 1, "both devices should have produced the same next instance")
        XCTAssertEqual(next.first?.startDate, today.adding(days: 7))
        XCTAssertNotNil(next.first?.repeatRule)
        XCTAssertEqual(one.snapshot.checklists[next.first!.id]?.map(\.title), ["Ferns"])
    }

    func testRepeatRuleWeekdays() {
        let rule = RepeatRule(unit: .week, weekdays: [2, 4]) // Mon, Wed
        let tuesday = Day(year: 2026, month: 11, day: 3)
        XCTAssertEqual(rule.next(after: tuesday, completedOn: tuesday), Day(year: 2026, month: 11, day: 4))
        let wednesday = Day(year: 2026, month: 11, day: 4)
        XCTAssertEqual(rule.next(after: wednesday, completedOn: wednesday), Day(year: 2026, month: 11, day: 9))
        let monthly = RepeatRule(unit: .month, mode: .afterCompletion)
        XCTAssertEqual(monthly.next(after: nil, completedOn: tuesday), Day(year: 2026, month: 12, day: 3))
    }

    func testWhenParsing() {
        XCTAssertEqual(When.parse("tod", today: today), .today)
        XCTAssertEqual(When.parse("tonight", today: today), .evening)
        XCTAssertEqual(When.parse("tom", today: today), .date(Day(year: 2026, month: 11, day: 4)))
        XCTAssertEqual(When.parse("fri", today: today), .date(Day(year: 2026, month: 11, day: 6)))
        XCTAssertEqual(When.parse("in 2 weeks", today: today), .date(Day(year: 2026, month: 11, day: 17)))
        XCTAssertEqual(When.parse("dec 25", today: today), .date(Day(year: 2026, month: 12, day: 25)))
        XCTAssertEqual(When.parse("1/15", today: today), .date(Day(year: 2027, month: 1, day: 15)))
        XCTAssertEqual(When.parse("someday", today: today), .someday)
        XCTAssertNil(When.parse("banana", today: today))
    }

    func testReorderTouchesOnlyMovedItem() {
        let store = DabbleStore(directory: nil)
        let a = store.addToDo("A"), b = store.addToDo("B"), c = store.addToDo("C")
        let before = store.seq
        store.reorder([c.id, a.id, b.id])
        XCTAssertEqual(store.seq - before, 1)
        XCTAssertEqual(store.lists(today: today).inbox()[0].items.map(\.id), [c.id, a.id, b.id])
    }

    func testUndoRestoresPreviousValues() {
        let store = DabbleStore(directory: nil)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        let todo = store.addToDo("Draft")
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        store.update(ToDo.self, todo.id) { $0.title = "Final" }
        undo.endUndoGrouping()
        undo.undo()
        XCTAssertEqual(store.todo(todo.id)?.title, "Draft")
    }

    func testPersistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DabbleStore(directory: directory)
        let todo = store.addToDo("Persist me", in: .today)
        store.saveNow()
        let reopened = DabbleStore(directory: directory)
        XCTAssertEqual(reopened.deviceID, store.deviceID)
        XCTAssertEqual(reopened.todo(todo.id)?.title, "Persist me")
        XCTAssertEqual(reopened.seq, store.seq)
    }

    func testSearch() {
        let store = DabbleStore(directory: nil)
        store.addProject("Garden")
        let todo = store.addToDo("Plant tulips", notes: "in the garden bed")
        let results = store.lists(today: today).search("garden")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.last?.id, todo.id)
    }

    func testURLScheme() throws {
        let store = DabbleStore(directory: nil)
        let project = store.addProject("Groceries")
        let url = URL(string: "dabble:///add?title=Oat%20milk&list=groceries&when=tomorrow&deadline=2026-11-10&tags=Errands&checklist-items=Two%0AOrganic")!
        guard case .added(let id) = try store.perform(url, today: today) else { return XCTFail() }
        let todo = try XCTUnwrap(store.todo(id))
        XCTAssertEqual(todo.projectID, project.id)
        XCTAssertEqual(todo.startDate, today.adding(days: 1))
        XCTAssertEqual(todo.deadline, Day(year: 2026, month: 11, day: 10))
        XCTAssertEqual(todo.tagIDs.compactMap { store.tag($0)?.title }, ["Errands"])
        XCTAssertEqual(store.snapshot.checklists[id]?.map(\.title), ["Two", "Organic"])
        XCTAssertEqual(try store.perform(URL(string: "dabble:///show?id=today")!), .show(.today))
    }
}
