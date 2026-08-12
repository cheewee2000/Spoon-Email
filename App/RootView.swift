import SwiftUI
import MailCore

enum Mailbox: Hashable {
    case unified
    case important
    case newsletters
    case updates
    case other
    case sent
    case account(String)   // account id
}

struct RootView: View {
    @State private var selection: Mailbox? = .unified

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Inbox") {
                    Label("Unified", systemImage: "tray.full").tag(Mailbox.unified)
                    Label("Important", systemImage: "star").tag(Mailbox.important)
                    Label("Newsletters", systemImage: "newspaper").tag(Mailbox.newsletters)
                    Label("Updates", systemImage: "bell").tag(Mailbox.updates)
                    Label("Other", systemImage: "tray").tag(Mailbox.other)
                }
                Section("Mail") {
                    Label("Sent", systemImage: "paperplane").tag(Mailbox.sent)
                }
            }
            .navigationTitle("SuperDuperHuman")
        } content: {
            Text("No mailbox synced yet")
                .foregroundStyle(.secondary)
        } detail: {
            Text("Select a conversation")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    RootView()
}
