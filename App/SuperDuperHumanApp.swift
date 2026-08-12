import SwiftUI
import MailCore

@main
struct SuperDuperHumanApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { model.compose() }
                    .keyboardShortcut("n")
                Button("Command Palette…") { model.showPalette.toggle() }
                    .keyboardShortcut("k")
                Button("Sync Now") { model.syncNow() }
                    .keyboardShortcut("r")
            }
        }
    }
}
