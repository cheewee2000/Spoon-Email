import Foundation
import GRDB

/// Holds scheduled/undoable sends and delivers them when due.
public actor OutboxManager {
    private let db: AppDatabase
    private let tokens: TokenManager
    private var accountEmails: [String: String] = [:]
    private var loopTask: Task<Void, Never>?

    /// Called with (accountId, threadId) once a message is actually delivered,
    /// so the app can pull that thread in immediately.
    private var onSent: (@Sendable (String, String) -> Void)?

    public init(db: AppDatabase, tokens: TokenManager) {
        self.db = db
        self.tokens = tokens
    }

    public func setOnSent(_ handler: @Sendable @escaping (String, String) -> Void) {
        onSent = handler
    }

    public func updateAccountEmails(_ emails: [String: String]) {
        accountEmails = emails
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task {
            while !Task.isCancelled {
                await pump()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    public func schedule(_ item: OutboxItem) async throws {
        try await db.writer.write { db in
            try item.save(db)
        }
    }

    /// Cancels a scheduled send (undo). Returns true if it was still pending.
    @discardableResult
    public func cancel(id: String) async -> Bool {
        (try? await db.writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ? AND state = 'scheduled'",
                           arguments: [id])
            return db.changesCount > 0
        }) ?? false
    }

    public func pump() async {
        let due: [OutboxItem] = (try? await db.writer.read { db in
            try OutboxItem
                .filter(sql: "state = 'scheduled' AND sendAt <= ?", arguments: [Date()])
                .fetchAll(db)
        }) ?? []

        for item in due {
            _ = try? await db.writer.write { db in
                try db.execute(sql: "UPDATE outbox SET state = 'sending' WHERE id = ?", arguments: [item.id])
            }
            do {
                let fromEmail = accountEmails[item.accountId] ?? ""
                let raw = MimeBuilder.build(
                    fromEmail: fromEmail,
                    to: item.toList, cc: item.ccList, bcc: item.bccList,
                    subject: item.subject, bodyText: item.bodyText, bodyHTML: item.bodyHTML,
                    quotedText: item.quotedText, quotedHTML: item.quotedHTML,
                    attachments: item.attachments,
                    inReplyTo: item.inReplyTo, references: item.references)
                let client = GmailClient(accountId: item.accountId, tokens: tokens)
                let sent = try await client.send(raw: raw, threadId: item.threadId)
                if !item.draftMessageId.isEmpty {
                    // The send replaced this draft: delete it from Gmail, then
                    // from the local cache. Gmail's history feed doesn't report
                    // draft deletions, so without the local purge the message
                    // keeps showing as a draft until the next launch's repair.
                    // If the server delete fails, leave the local row alone so
                    // the two stay in agreement.
                    do {
                        try await client.deleteDraft(messageId: item.draftMessageId)
                        try await db.purgeDraft(accountId: item.accountId,
                                                messageId: item.draftMessageId)
                    } catch {}
                }
                _ = try? await db.writer.write { db in
                    try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [item.id])
                }
                // The delivered message's own thread — for a new conversation
                // Gmail assigns one, so this isn't always item.threadId.
                onSent?(item.accountId, sent.threadId)
            } catch {
                _ = try? await db.writer.write { db in
                    try db.execute(sql: "UPDATE outbox SET state = 'failed', lastError = ? WHERE id = ?",
                                   arguments: [error.localizedDescription, item.id])
                }
            }
        }

        // Auto-retry failed sends after a minute
        _ = try? await db.writer.write { db in
            try db.execute(sql: """
                UPDATE outbox SET state = 'scheduled', sendAt = ?
                WHERE state = 'failed' AND sendAt <= ?
                """, arguments: [Date().addingTimeInterval(60), Date().addingTimeInterval(-60)])
        }
    }
}
