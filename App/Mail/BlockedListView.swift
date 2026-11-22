import SwiftUI
import MailCore

struct BlockedListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [BlockRule] = []
    @State private var newPattern = ""

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
            HStack {
                TextField("name@example.com or example.com", text: $newPattern)
                    .textFieldStyle(.plain)
                    .font(CWT.font(12))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .onSubmit(add)
                Button("Block", action: add)
                    .buttonStyle(.square)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            Hairline()
            if rules.isEmpty {
                EmptyState(title: "Nothing blocked", systemImage: "hand.raised",
                           detail: "Type an address or domain above, or block from a message's ••• menu.")
            } else {
                List(rules) { rule in
                    HStack {
                        Image(systemName: rule.kind == "domain" ? "globe" : "person.slash")
                            .foregroundStyle(CWT.ink2)
                        Text(rule.pattern)
                            .font(CWT.font(12))
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

    private func add() {
        let typed = newPattern
        Task {
            guard let rule = await model.block(typed: typed) else { return }
            newPattern = ""
            rules.removeAll { $0.pattern == rule.pattern }
            rules.insert(rule, at: 0)
        }
    }
}
