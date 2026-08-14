import SwiftUI
import MailCore

/// Collects the user's Google OAuth client ID — the one piece of setup Spoon
/// can't do for them. Presented the first time Add Account is clicked; the
/// saved ID lands in UserDefaults and takes effect immediately.
struct ClientSetupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""

    private var isValid: Bool {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(".apps.googleusercontent.com")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Spoon Email to Gmail")
                .font(.title2).bold()
            Text("Spoon Email talks to Gmail with your own free Google OAuth client — your mail never touches anyone else's server. One-time setup, about 5 minutes:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open [console.cloud.google.com](https://console.cloud.google.com) and create a project (any name).")
                step(2, "**APIs & Services → Library** → enable the **Gmail API**.")
                step(3, "**OAuth consent screen** → External → **Audience: Testing** → add each Gmail address you'll connect as a **Test user**.")
                step(4, "**Credentials → Create credentials → OAuth client ID** → application type **iOS** → bundle ID `com.cwandt.spoon`.")
                step(5, "Copy the client ID and paste it here:")
            }
            TextField("1234-abc.apps.googleusercontent.com", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save & Sign In") {
                    Config.setGoogleClientID(clientID)
                    dismiss()
                    model.addAccount()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 480)
        #endif
        .onAppear { clientID = Config.googleClientID }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// Full-window empty state for a fresh install: no accounts yet, so the
/// board and lists behind it are blank anyway.
struct WelcomeView: View {
    @ObservedObject var store: AccountStore
    let addAccount: () -> Void

    var body: some View {
        if store.accounts.isEmpty {
            VStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .frame(width: 56, height: 56)
                Text("Spoon Email")
                    .font(.largeTitle).bold()
                Text("A fast, keyboard-first Gmail client.\nConnect a Google account to begin.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Add Google Account…", action: addAccount)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background()
        }
    }
}
