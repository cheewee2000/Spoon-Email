import Foundation
import SwiftUI
import GRDB
import MailCore

@MainActor
final class AppModel: ObservableObject {
    let db: AppDatabase
    let accountStore: AccountStore
    let syncEngine: SyncEngine
    let outbox: OutboxManager

    @Published var lastError: String?
    @Published var syncStatus: String?
    @Published var draft: ComposeDraft?
    @Published var undoToast: (id: String, until: Date)?

    static let undoWindow: TimeInterval = 10

    private static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]

    init() {
        do {
            db = try AppDatabase.open()
        } catch {
            fatalError("Cannot open database: \(error)")
        }
        accountStore = AccountStore(db: db, config: GoogleOAuthConfig(clientID: Config.googleClientID))
        syncEngine = SyncEngine(db: db, tokens: accountStore.tokens)
        outbox = OutboxManager(db: db, tokens: accountStore.tokens)
        Task {
            await syncEngine.setStatusHandler { [weak self] status in
                Task { @MainActor in self?.syncStatus = status }
            }
            await outbox.setOnSent { [weak self] _ in
                Task { @MainActor in self?.syncNow() }
            }
            await pushAccountEmails()
            await outbox.start()
            syncNow()
        }
    }

    private func pushAccountEmails() async {
        let emails = Dictionary(uniqueKeysWithValues: accountStore.accounts.map { ($0.id, $0.email) })
        await outbox.updateAccountEmails(emails)
    }

    // MARK: - Accounts

    func addAccount() {
        Task {
            do {
                try await accountStore.addAccount()
                await pushAccountEmails()
                syncNow()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func accountEmail(_ id: String) -> String {
        accountStore.accounts.first { $0.id == id }?.email ?? ""
    }

    func accountColor(_ id: String) -> Color {
        guard let idx = accountStore.accounts.firstIndex(where: { $0.id == id }) else { return .blue }
        return Self.palette[idx % Self.palette.count]
    }

    // MARK: - Sync

    func syncNow() {
        let accounts = accountStore.accounts
        guard !accounts.isEmpty else { return }
        Task { await syncEngine.syncAll(accounts: accounts) }
    }

    // MARK: - Thread actions

    func archive(_ thread: MailThread) {
        Task { await syncEngine.archive(accountId: thread.accountId, threadId: thread.id) }
    }

    func markRead(_ thread: MailThread, read: Bool) {
        Task { await syncEngine.markRead(accountId: thread.accountId, threadId: thread.id, read: read) }
    }

    func toggleStar(_ thread: MailThread) {
        Task { await syncEngine.toggleStar(accountId: thread.accountId, threadId: thread.id, starred: !thread.isStarred) }
    }

    // MARK: - Compose

    func compose() {
        guard let first = accountStore.accounts.first else {
            lastError = "Add an account first."
            return
        }
        draft = ComposeDraft(accountId: first.id)
    }

    func reply(to thread: MailThread, all: Bool) {
        Task {
            guard let last = lastMessage(in: thread) else { return }
            let myEmail = accountEmail(thread.accountId).lowercased()
            var to: String
            if last.fromEmail.lowercased() == myEmail {
                to = last.toList
            } else {
                to = last.fromName == last.fromEmail ? last.fromEmail : "\(last.fromName) <\(last.fromEmail)>"
            }
            var cc = ""
            if all {
                let extras = (last.toList + "," + last.ccList)
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.lowercased().contains(myEmail) && $0 != to }
                cc = extras.joined(separator: ", ")
            }
            let subject = thread.subject.hasPrefix("Re:") ? thread.subject : "Re: \(thread.subject)"
            let references = (last.referencesHeader + " " + last.messageIdHeader)
                .trimmingCharacters(in: .whitespaces)
            draft = ComposeDraft(
                accountId: thread.accountId, to: to, cc: cc, subject: subject,
                body: "\n\n" + quote(last),
                threadId: thread.id, inReplyTo: last.messageIdHeader, references: references)
        }
    }

    func forward(_ thread: MailThread) {
        guard let last = lastMessage(in: thread) else { return }
        let subject = thread.subject.hasPrefix("Fwd:") ? thread.subject : "Fwd: \(thread.subject)"
        draft = ComposeDraft(accountId: thread.accountId, subject: subject,
                             body: "\n\n---------- Forwarded message ----------\n" + quote(last))
    }

    private func lastMessage(in thread: MailThread) -> Message? {
        try? db.writer.read { db in
            try Message.fetchOne(
                db,
                sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY date DESC LIMIT 1",
                arguments: [thread.accountId, thread.id])
        }
    }

    private func quote(_ m: Message) -> String {
        let text = m.bodyText ?? MimeParser.stripHTML(m.bodyHTML ?? "")
        let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let date = m.date.formatted(date: .abbreviated, time: .shortened)
        return "On \(date), \(m.fromName) <\(m.fromEmail)> wrote:\n\(quoted)"
    }

    func suggestContacts(_ query: String) -> [(name: String, email: String)] {
        let rows = (try? db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT fromName, fromEmail, MAX(date) d FROM message
                WHERE fromEmail LIKE ? OR fromName LIKE ?
                GROUP BY fromEmail ORDER BY d DESC LIMIT 5
                """, arguments: ["%\(query)%", "%\(query)%"])
        }) ?? []
        return rows.map { ($0["fromName"] ?? "", $0["fromEmail"] ?? "") }
    }

    // MARK: - Send / undo send / send later

    func send(draft: ComposeDraft, at date: Date?) {
        let sendAt = date ?? Date().addingTimeInterval(Self.undoWindow)
        let item = OutboxItem(
            accountId: draft.accountId, threadId: draft.threadId,
            toList: draft.to, ccList: draft.cc, bccList: draft.bcc,
            subject: draft.subject, bodyText: draft.body,
            inReplyTo: draft.inReplyTo, references: draft.references,
            sendAt: sendAt)
        Task {
            do {
                try await outbox.schedule(item)
                if date == nil {
                    undoToast = (item.id, sendAt)
                } else {
                    syncStatus = "Scheduled for \(sendAt.formatted(date: .abbreviated, time: .shortened))"
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if syncStatus?.hasPrefix("Scheduled") == true { syncStatus = nil }
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func undoSend() {
        guard let toast = undoToast else { return }
        undoToast = nil
        Task {
            let cancelled = await outbox.cancel(id: toast.id)
            if !cancelled {
                lastError = "Too late — the message was already sent."
            }
        }
    }
}
