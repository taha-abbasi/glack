import AppKit
import Carbon
import Foundation

/// Carbon-backed global hotkey — fires the registered handler even when
/// Glack isn't frontmost. SwiftUI's `.keyboardShortcut` only works at
/// scene level (Glack must be focused), so this is the only path to a
/// true "summon from any app" shortcut.
///
/// Defaults to **⌘⇧G** — matches Slack's "jump to" pattern. Hardcoded for
/// now; could be made user-configurable via Settings later.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var fireHandler: (() -> Void)?

    /// Install the app-level Carbon event handler and register the hotkey.
    /// Call once at app launch.
    func install(action: @escaping () -> Void) {
        fireHandler = action

        // 1. Install the application-wide event handler. Carbon dispatches
        //    every registered hotkey through this single callback; the
        //    `userData` slot lets us route back to Swift.
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.fireHandler?() }
                return noErr
            },
            1, &eventSpec, selfPtr, &eventHandlerRef
        )
        guard installStatus == noErr else {
            Log.app.error("GlobalHotkey: InstallEventHandler failed status=\(installStatus, privacy: .public)")
            return
        }

        // 2. Register ⌘⇧G. Carbon expects a 4-char-code signature for the
        //    hotkey ID — used internally to disambiguate multiple hotkeys
        //    within the same app.
        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("GLCK"), id: 1)
        let keyCodeG: UInt32 = UInt32(kVK_ANSI_G)
        let mods = UInt32(cmdKey) | UInt32(shiftKey)
        var newRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(keyCodeG, mods, hotKeyID,
                                            GetApplicationEventTarget(), 0, &newRef)
        if regStatus == noErr {
            self.hotKeyRef = newRef
            Log.app.info("GlobalHotkey: registered ⌘⇧G")
        } else {
            // -9878 = eventHotKeyExistsErr — another app has the same hotkey.
            Log.app.error("GlobalHotkey: RegisterEventHotKey failed status=\(regStatus, privacy: .public)")
        }
    }

    func uninstall() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    /// `OSType("GLCK")` — Carbon's 4-character-code packing.
    private static func fourCharCode(_ s: String) -> OSType {
        var result: OSType = 0
        for byte in s.utf8.prefix(4) {
            result = (result << 8) | OSType(byte)
        }
        return result
    }
}
