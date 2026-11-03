import DabbleKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.undoManager) private var undoManager
    @State private var router = Router()

    var body: some View {
        @Bindable var router = router
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    HomeView(selection: $router.selection)
                } detail: {
                    NavigationStack(path: $router.path) {
                        ListScreen(list: router.selection ?? .today)
                            .id(router.selection)
                            .navigationDestination(for: ListID.self) { ListScreen(list: $0) }
                    }
                }
            } else {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: ListID.self) { ListScreen(list: $0) }
                }
            }
        }
        .environment(router)
        .sheet(item: $router.detail, onDismiss: cleanUpAfterDetail) { target in
            ToDoDetailView(target: target)
                .environment(model)
                .environment(router)
        }
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
                .environment(model)
                .environment(router)
        }
        .sensoryFeedback(.success, trigger: router.completionTick)
        .onOpenURL(perform: handle)
        .onAppear {
            router.isCompact = sizeClass != .regular
            model.store.undoManager = undoManager
            if !AppContainer.launched {
                AppContainer.launched = true
                model.launch()
            }
        }
        .onChange(of: sizeClass) { _, newValue in
            router.isCompact = newValue != .regular
        }
        .onChange(of: undoManager) { _, newValue in
            model.store.undoManager = newValue
        }
    }

    /// A brand-new to-do left empty is discarded, along with checklist items
    /// that never got a title.
    private func cleanUpAfterDetail() {
        guard let target = router.lastDetail else { return }
        let store = model.store
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let checklist = store.snapshot.checklists[target.id] ?? []
            for item in checklist where item.title.trimmingCharacters(in: .whitespaces).isEmpty {
                store.delete(item.id)
            }
            if target.isNew, let todo = store.todo(target.id), !todo.isTrashed,
               todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, todo.notes.isEmpty,
               (store.snapshot.checklists[todo.id] ?? []).isEmpty {
                store.delete(todo.id)
            }
        }
    }

    private func handle(_ url: URL) {
        guard let command = try? model.store.perform(url, today: model.today) else { return }
        switch command {
        case .show(let list):
            router.detail = nil
            router.show(list)
        case .showItem(let id):
            if model.store.todo(id) != nil {
                router.open(id)
            }
        case .search(let query):
            router.path = []
            router.searchText = query
        case .added:
            break
        }
    }
}
