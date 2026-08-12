import SwiftUI
import MailCore

struct ComposeDraft: Identifiable {
    let id = UUID()
    var accountId: String
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    var threadId: String?
    var inReplyTo: String = ""
    var references: String = ""
}

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var showCcBcc = false
    @State private var suggestions: [(name: String, email: String)] = []
    @FocusState private var focus: Field?

    enum Field { case to, cc, bcc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("From").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $draft.accountId) {
                        ForEach(model.accountStore.accounts) { account in
                            Text(account.email).tag(account.id)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("To").foregroundStyle(.secondary)
                    TextField("", text: $draft.to)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .to)
                        .onChange(of: draft.to) { updateSuggestions() }
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                if !suggestions.isEmpty && focus == .to {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(suggestions, id: \.email) { s in
                                Button {
                                    applySuggestion(s)
                                } label: {
                                    Text("\(s.name) <\(s.email)>")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                            }
                        }
                    }
                }
                if showCcBcc {
                    GridRow {
                        Text("Cc").foregroundStyle(.secondary)
                        TextField("", text: $draft.cc)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .cc)
                    }
                    GridRow {
                        Text("Bcc").foregroundStyle(.secondary)
                        TextField("", text: $draft.bcc)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .bcc)
                    }
                } else {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Button("Add Cc/Bcc") { showCcBcc = true }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                GridRow {
                    Text("Subject").foregroundStyle(.secondary)
                    TextField("", text: $draft.subject)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .subject)
                }
            }
            .padding(12)
            Divider()
            TextEditor(text: $draft.body)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .focused($focus, equals: .body)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Menu("Send Later") {
                    Button("In 1 Hour") { sendAt(Date().addingTimeInterval(3600)) }
                    Button("Tonight 8 PM") { sendAt(next(hour: 20)) }
                    Button("Tomorrow 9 AM") { sendAt(next(hour: 9, forceTomorrow: true)) }
                }
                .fixedSize()
                Button("Send") { sendAt(nil) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
    }

    private func sendAt(_ date: Date?) {
        model.send(draft: draft, at: date)
        dismiss()
    }

    private func next(hour: Int, forceTomorrow: Bool = false) -> Date {
        let cal = Calendar.current
        var date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        if forceTomorrow || date <= Date() {
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        return date
    }

    private func updateSuggestions() {
        let query = draft.to.components(separatedBy: ",").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard query.count >= 2 else {
            suggestions = []
            return
        }
        suggestions = model.suggestContacts(query)
    }

    private func applySuggestion(_ s: (name: String, email: String)) {
        var parts = draft.to.components(separatedBy: ",")
        parts[parts.count - 1] = " \(s.name) <\(s.email)>"
        draft.to = parts.joined(separator: ",").trimmingCharacters(in: .whitespaces)
        suggestions = []
    }
}
