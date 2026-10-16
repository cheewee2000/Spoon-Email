import SwiftUI
import MailCore
#if os(macOS)
import Sparkle
#endif

@main
struct SpoonApp: App {
    @StateObject private var model = AppModel.shared
    #if os(macOS)
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    init() {
        CWT.registerFonts()
        #if os(iOS)
        CWT.applyAppearance()
        #endif
        #if os(iOS)
        // Registration has to land before launch finishes, and this runs in
        // background launches too — where no scene is ever created.
        BackgroundRefresh.register()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
        .commands {
            // Disabled while composing so ⌘Z falls through the responder
            // chain to the text editor's own undo instead of un-archiving
            // something behind the sheet.
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle) { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo || model.draft != nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Message") { model.compose() }
                    .keyboardShortcut("n")
                Button("Command Palette…") { model.showPalette.toggle() }
                    .keyboardShortcut("k")
                Button("Sync Now") { model.syncNow() }
                    .keyboardShortcut("r")
            }
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.updater.checkForUpdates() }
            }
            // Lands in the Edit menu, where Find belongs.
            CommandGroup(after: .textEditing) {
                Button("Find") { model.focusSearch() }
                    .keyboardShortcut("f")
            }
            #endif
        }
    }
}
