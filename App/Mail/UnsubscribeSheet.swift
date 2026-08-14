import SwiftUI
import MailCore

/// Confirm → progress → result for a single unsubscribe.
struct UnsubscribeSheet: View {
    @EnvironmentObject var model: AppModel
    let session: UnsubscribeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }

            Text(session.sender)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if case .working = session.stage {
                ProgressView()
                    .controlSize(.small)
            }

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private var buttons: some View {
        switch session.stage {
        case .confirm:
            Button("Cancel", role: .cancel) { model.dismissUnsubscribe() }
                .keyboardShortcut(.cancelAction)
            Button("Unsubscribe") { model.confirmUnsubscribe() }
                .keyboardShortcut(.defaultAction)
        case .working:
            Button("Cancel", role: .cancel) { model.dismissUnsubscribe() }
                .disabled(true)
        case .browserPending(let url):
            Button("Open Page Again") {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                Task { await UIApplication.shared.open(url) }
                #endif
            }
            Button("Not Now", role: .cancel) { model.dismissUnsubscribe() }
                .keyboardShortcut(.cancelAction)
            Button("Done — Archive") { model.finishUnsubscribeFromBrowser() }
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Done") { model.dismissUnsubscribe() }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close", role: .cancel) { model.dismissUnsubscribe() }
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { model.confirmUnsubscribe() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var title: String {
        switch session.stage {
        case .confirm:        return "Unsubscribe?"
        case .working:        return "Unsubscribing…"
        case .browserPending: return "Finish in your browser"
        case .done:           return "Unsubscribed"
        case .failed:         return "Unsubscribe failed"
        }
    }

    private var detail: String {
        switch session.stage {
        case .confirm:
            return session.method + " The conversation is archived once it goes through."
        case .working:
            return "Sending the unsubscribe request…"
        case .browserPending:
            return "The sender's unsubscribe page is open in your browser. Complete it there, then archive this conversation."
        case .done(let text):
            return text
        case .failed(let text):
            return text
        }
    }

    private var icon: String {
        switch session.stage {
        case .done:   return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default:      return "envelope.arrow.triangle.branch"
        }
    }

    private var tint: Color {
        switch session.stage {
        case .done:   return .green
        case .failed: return .orange
        default:      return .accentColor
        }
    }
}
