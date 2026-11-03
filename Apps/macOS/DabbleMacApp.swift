import AppKit
import DabbleKit
import SwiftUI

@main
struct DabbleMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Dabble", id: "main", for: ListID.self) { $list in
            MainWindow(model: appDelegate.model, list: $list)
        }
        .defaultSize(width: 1060, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            DabbleCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

/// App lifecycle: launch, foreground/background, Quick Entry.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quickEntry: QuickEntryController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()
        model.launch()
        quickEntry = QuickEntryController(model: model)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.becameActive()
    }

    func applicationWillResignActive(_ notification: Notification) {
        model.willResignActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.willResignActive()
    }

    /// Keep running with no windows so the Quick Entry shortcut still works.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
