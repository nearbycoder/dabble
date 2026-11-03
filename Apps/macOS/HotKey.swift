import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's `RegisterEventHotKey`, which
/// works inside the App Sandbox without Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var reference: EventHotKeyRef?
    private let id: UInt32

    /// Returns nil if the shortcut is already taken by another app.
    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4442_4C45), id: id) // "DBLE"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
