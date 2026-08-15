import SwiftUI
import MailCore

struct BlockedListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [BlockRule] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Blocked senders & domains")
                    .font(CWT.title)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.square)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)
            Hairline()
            if rules.isEmpty {
                EmptyState(title: "Nothing blocked",
                           detail: "Block a sender or domain from a message's More menu.")
            } else {
                List(rules) { rule in
                    HStack(spacing: 10) {
                        Tag(text: rule.kind == "domain" ? "DOMAIN" : "SENDER",
                            color: CWT.ink3, inverted: false)
                        Text(rule.pattern)
                            .font(CWT.font(12))
                        Spacer()
                        Button("×") {
                            model.unblock(rule)
                            rules.removeAll { $0.id == rule.id }
                        }
                        .buttonStyle(.textAction(CWT.ink2))
                        .help("Unblock")
                    }
                    .listRowSeparatorTint(CWT.hairline)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
