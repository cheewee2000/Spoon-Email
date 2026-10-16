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
            // ⌘Z un-archives in the inbox. In the composer's window it has
            // to reach the text view's own undo stack instead — and that only
            // ever happens through a menu item sending undo: down the
            // responder chain, which replacing this group had removed.
            CommandGroup(replacing: .undoRedo) {
                Button(model.draft == nil ? model.undoTitle : "Undo") {
                    #if os(macOS)
                    if ComposeWindowHost.shared.owns(NSApp.keyWindow) {
                        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                        return
                    }
                    #endif
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo && model.draft == nil)
                #if os(macOS)
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.draft == nil)
                #endif
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
