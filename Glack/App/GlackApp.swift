import SwiftUI

@main
struct GlackApp: App {
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
