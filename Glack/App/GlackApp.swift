import AppKit
import SwiftUI

@main
struct GlackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Glack") {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

/// Carries the lifecycle bits SwiftUI doesn't surface — currently the
/// global ⌘⇧G hotkey registration on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GlobalHotkey.shared.install { [weak self] in
            self?.summon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkey.shared.uninstall()
    }

    /// Bring Glack to the foreground + reveal the main window.
    /// Triggered by the global hotkey from any other app.
    private func summon() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
