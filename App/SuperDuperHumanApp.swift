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
    }
}
