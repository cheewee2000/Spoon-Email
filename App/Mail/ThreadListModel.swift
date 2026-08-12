import Foundation
import SwiftUI
import GRDB
import MailCore

/// Live thread list for one mailbox, backed by GRDB ValueObservation.
@MainActor
final class ThreadListModel: ObservableObject {
    @Published private(set) var threads: [MailThread] = []
    private var cancellable: AnyDatabaseCancellable?
    private(set) var filter: MailboxFilter = .unified

    func observe(db: AppDatabase, filter: MailboxFilter) {
        self.filter = filter
        cancellable?.cancel()
        let observation = ValueObservation.tracking { db in
            try filter.fetch(db)
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("thread observation error: \(error)")
        } onChange: { [weak self] threads in
            self?.threads = threads
        }
    }

    /// Live FTS5 search across all accounts.
    func observeSearch(db: AppDatabase, query: String) {
        cancellable?.cancel()
        guard let match = Self.ftsQuery(query) else {
            threads = []
            return
        }
        let observation = ValueObservation.tracking { db in
            try MailThread.fetchAll(db, sql: """
                SELECT t.* FROM thread t WHERE EXISTS (
                    SELECT 1 FROM message_fts
                    WHERE message_fts MATCH ?
                      AND message_fts.accountId = t.accountId
                      AND message_fts.threadId = t.id
                )
                ORDER BY t.lastDate DESC LIMIT 200
                """, arguments: [match])
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("search observation error: \(error)")
        } onChange: { [weak self] threads in
            self?.threads = threads
        }
    }

    /// "foo bar" → "\"foo\"* \"bar\"*" (prefix-match every term, implicit AND)
    static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

/// Live message list (plus attachment metadata) for one thread.
@MainActor
final class ThreadDetailModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var attachments: [String: [Attachment]] = [:]
    private var cancellable: AnyDatabaseCancellable?

    func observe(db: AppDatabase, thread: MailThread) {
        cancellable?.cancel()
        let accountId = thread.accountId
        let threadId = thread.id
        let observation = ValueObservation.tracking { db -> ([Message], [Attachment]) in
            let messages = try Message.fetchAll(
                db,
                sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY date",
                arguments: [accountId, threadId])
            let attachments = try Attachment.fetchAll(
                db,
                sql: """
                SELECT a.* FROM attachment a
                JOIN message m ON m.accountId = a.accountId AND m.id = a.messageId
                WHERE m.accountId = ? AND m.threadId = ?
                """,
                arguments: [accountId, threadId])
            return (messages, attachments)
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("message observation error: \(error)")
        } onChange: { [weak self] (messages, attachments) in
            self?.messages = messages
            self?.attachments = Dictionary(grouping: attachments, by: \.messageId)
        }
    }
}
