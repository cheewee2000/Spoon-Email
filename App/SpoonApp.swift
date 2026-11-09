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
        #if os(macOS)
        // Same reason as handlesExternalEvents below: a tab is a second window.
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
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
                // One window, always: a mailto: link or widget tap would
                // otherwise open a second one on the same AppModel, and only
                // one window's reader follows the selection — archive with e
                // in the other and the old email stays put.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

#if os(macOS)
struct SettingsView: View {
    private let mailto = URL(string: "mailto:")!
    @State private var isDefault = false

    var body: some View {
        HStack {
            Text(isDefault ? "Spoon is your default email app." : "Mail links open another app.")
                .font(CWT.font(12))
            Spacer()
            Button("Make Spoon the Default") {
                // macOS asks the user to confirm before switching.
                Task {
                    try? await NSWorkspace.shared.setDefaultApplication(
                        at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
                    refresh()
                }
            }
            .disabled(isDefault)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        isDefault = NSWorkspace.shared.urlForApplication(toOpen: mailto)
            .flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }
}
#endif
