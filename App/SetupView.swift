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
            Text("Google OAuth client")
                .font(CWT.title)
            Text("Spoon Email ships with CW&T's Google client, which only works for addresses on our test-user list. Anyone else can use their own free client — your mail never touches anyone else's server either way. One-time setup, about 5 minutes:")
                .font(CWT.font(12))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open [console.cloud.google.com](https://console.cloud.google.com) and create a project (any name).")
                step(2, "**APIs & Services → Library** → enable the **Gmail API**.")
                step(3, "**OAuth consent screen** → External → fill in the name and email → **Publish app** (Audience: In production). Leaving it in Testing signs you out every 7 days. Sign-in will show a \"Google hasn't verified this app\" screen — Advanced → Go to… — once per account.")
                step(4, "**Credentials → Create credentials → OAuth client ID** → application type **iOS** → bundle ID `com.cwandt.spoon`.")
                step(5, "Copy the client ID and paste it here:")
            }
            TextField("1234-abc.apps.googleusercontent.com", text: $clientID)
                .textFieldStyle(.plain)
                .font(CWT.font(12))
                .padding(8)
                .overlay(Rectangle().strokeBorder(CWT.hairline, lineWidth: 1))
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
            HStack(spacing: 8) {
                if Config.usesCustomClientID {
                    Button("Use CW&T's Client") {
                        Config.setGoogleClientID("")
                        clientID = Config.googleClientID
                    }
                    .buttonStyle(.textAction(CWT.ink2))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.square)
                Button("Save & Sign In") {
                    Config.setGoogleClientID(clientID)
                    dismiss()
                    model.addAccount()
                }
                .buttonStyle(.squarePrimary)
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
            Text("\(n).")
                .font(CWT.font(12, bold: true))
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(CWT.font(12))
    }
}

/// Full-window empty state for a fresh install: no accounts yet, so the
/// board and lists behind it are blank anyway.
struct WelcomeView: View {
    @ObservedObject var store: AccountStore
    let addAccount: () -> Void

    var body: some View {
        if store.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Image("Logo")
                    .resizable()
                    .frame(width: 40, height: 40)
                Text("Spoon Email")
                    .font(CWT.display)
                Text("A fast, keyboard-first Gmail client.\nConnect a Google account to begin.")
                    .font(CWT.font(12))
                    .foregroundStyle(CWT.ink2)
                Button("Add Google Account →", action: addAccount)
                    .buttonStyle(.squarePrimary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CWT.paper)
        }
    }
}
