import DabbleKit
import SwiftUI

/// Long-press menu for a row.
struct ItemMenu: View {
    let item: Item
    let list: ListID
    var present: (ItemSheet) -> Void
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    private var store: DabbleStore { model.store }

    var body: some View {
        if list == .trash {
            Button("Put Back", systemImage: "arrow.uturn.backward") { store.restore([item.id]) }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) { store.delete(item.id) }
        } else {
            switch item {
            case .todo(let todo): todoMenu(todo)
            case .project(let project): projectMenu(project)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private func todoMenu(_ todo: ToDo) -> some View {
        let id = todo.id
        Section {
            if todo.isOpen {
                Button("Complete", systemImage: "checkmark.circle") {
                    withAnimation { store.setStatus([id], .completed, today: model.today) }
                    router.didComplete()
                }
                Button("Cancel To-Do", systemImage: "xmark.circle") {
                    withAnimation { store.setStatus([id], .canceled, today: model.today) }
                }
            } else {
                Button("Mark as Open", systemImage: "circle") {
                    withAnimation { store.setStatus([id], .open, today: model.today) }
                }
            }
        }
        Section {
            Button("When", systemImage: "calendar") { present(.when([id])) }
            Button("Deadline", systemImage: "flag") { present(.deadline([id])) }
            Button("Move", systemImage: "arrow.right.circle") { present(.move([id])) }
            Button("Tags", systemImage: "tag") { present(.tags([id])) }
            Button("Repeat", systemImage: "arrow.triangle.2.circlepath") { present(.repeatRule(id)) }
        }
        Section {
            Button("Duplicate", systemImage: "plus.square.on.square") {
                withAnimation { _ = store.duplicateToDo(id) }
            }
            Button("Convert to Project", systemImage: "circle.circle") {
                if let project = store.convertToProject(id) {
                    router.push(.project(project.id))
                }
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            withAnimation { store.trash([id]) }
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        let id = project.id
        Button("Open", systemImage: "arrow.right") { router.push(.project(id)) }
        Section {
            if project.isOpen {
                Button("Complete Project", systemImage: "checkmark.circle") {
                    withAnimation { store.setStatus([id], .completed, today: model.today) }
                    router.didComplete()
                }
            } else {
                Button("Mark as Open", systemImage: "circle") { store.setStatus([id], .open, today: model.today) }
            }
        }
        Section {
            Button("When", systemImage: "calendar") { present(.when([id])) }
            Button("Deadline", systemImage: "flag") { present(.deadline([id])) }
            Button("Move", systemImage: "arrow.right.circle") { present(.move([id])) }
            Button("Tags", systemImage: "tag") { present(.tags([id])) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            withAnimation { store.trash([id]) }
        }
    }
}
