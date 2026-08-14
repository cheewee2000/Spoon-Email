import SwiftUI

#if os(macOS)
import AppKit

/// Puts the composer in a real window instead of a sheet, so it can be moved
/// by its title bar and resized from any edge or corner. The size and position
/// are remembered between messages.
///
/// Shared rather than owned by a view: SwiftUI is free to rebuild the view that
/// drives this, and the open window must not go down with it.
@MainActor
final class ComposeWindowHost: NSObject, NSWindowDelegate {
    static let shared = ComposeWindowHost()

    private var window: NSWindow?
    /// Called when the window closes on its own (the red button), so the app
    /// can drop the draft it was showing.
    var onWindowClosed: (() -> Void)?

    func show<Content: View>(_ content: Content, title: String) {
        let hosting = NSHostingController(rootView: content)
        if let window {
            window.contentViewController = hosting
            window.title = title
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 560))
        window.minSize = NSSize(width: 480, height: 360)
        window.delegate = self
        // Remembers, and restores, whatever the user last dragged it to.
        window.setFrameAutosaveName("ComposeWindow")
        if !window.setFrameUsingName("ComposeWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Tears the window down without reporting it as a user-initiated close.
    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onWindowClosed?()
    }
}

/// Mirrors an optional draft into a compose window.
struct ComposeWindowPresenter: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .onAppear { ComposeWindowHost.shared.onWindowClosed = { model.draft = nil } }
            .onChange(of: model.draft?.id) { present() }
    }

    private func present() {
        guard let draft = model.draft else {
            ComposeWindowHost.shared.close()
            return
        }
        ComposeWindowHost.shared.show(
            ComposeView(draft: draft, onClose: { model.draft = nil })
                .environmentObject(model),
            title: draft.subject.isEmpty ? "New Message" : draft.subject)
    }
}
#endif

extension View {
    /// The composer is a movable, resizable window on the Mac and a sheet on
    /// iOS, where windows aren't a thing.
    @ViewBuilder
    func composeWindow() -> some View {
        #if os(macOS)
        modifier(ComposeWindowPresenter())
        #else
        self
        #endif
    }
}
