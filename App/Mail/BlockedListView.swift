import SwiftUI
import MailCore

struct BlockedListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [BlockRule] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Blocked Senders & Domains")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
            Divider()
            if rules.isEmpty {
                ContentUnavailableView(
                    "Nothing Blocked",
                    systemImage: "hand.raised",
                    description: Text("Block a sender or domain from a message's ••• menu.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(rules) { rule in
                    HStack {
                        Image(systemName: rule.kind == "domain" ? "globe" : "person.slash")
                            .foregroundStyle(.secondary)
                        Text(rule.pattern)
                        Spacer()
                        Button {
                            model.unblock(rule)
                            rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Unblock")
                    }
                }
                .listStyle(.plain)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
        .task {
            rules = await model.loadBlockRules()
        }
    }
}
