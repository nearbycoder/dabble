import DabbleKit
import SwiftUI

/// One model per process, shared by every window and by App Intents.
enum AppContainer {
    static let model = AppModel()
    static var launched = false
}

@main
struct DabbleApp: App {
    @State private var model = AppContainer.model
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.willResignActive()
            default: break
            }
        }
    }
}
