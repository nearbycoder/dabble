import AppKit
import DabbleKit
import SwiftUI

struct MainWindow: View {
    let model: AppModel
    @Binding var restoredList: ListID?
    @State private var state: WindowState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, list: Binding<ListID?>) {
        self.model = model
        _restoredList = list
        _state = State(initialValue: WindowState(model: model))
    }

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 236, max: 340)
        } detail: {
            ListView()
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .navigationTitle(state.current.title(in: model.store))
        .toolbar(removing: .title)
        .overlay {
            if state.quickFindQuery != nil {
                QuickFindView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: state.quickFindQuery != nil)
        .background(WindowReader { state.window = $0 })
        .environment(state)
        .environment(model)
        .focusedSceneValue(\.windowState, state)
        .frame(minWidth: 680, minHeight: 440)
        .onAppear {
            if let restoredList { state.list = restoredList }
            model.store.undoManager = undoManager
            NewWindowRequest.openWindow = openWindow
        }
        .onChange(of: state.list) { _, list in restoredList = list }
        .onChange(of: activeState) { _, active in
            if active == .key { model.store.undoManager = undoManager }
        }
        .onChange(of: undoManager) { _, manager in
            if activeState == .key { model.store.undoManager = manager }
        }
        .onOpenURL(perform: handle)
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    private func handle(_ url: URL) {
        do {
            switch try model.store.perform(url, today: model.today) {
            case .show(let list): state.navigate(to: list)
            case .showItem(let id): state.reveal(id)
            case .search(let query): state.openQuickFind(query)
            case .added: break
            }
        } catch {
            NSSound.beep()
        }
    }
}

/// Hands back the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}
