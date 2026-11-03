import DabbleKit
import SwiftUI

@main
struct DabbleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Text("Dabble")
                .environment(model)
                .onAppear { model.launch() }
        }
    }
}
