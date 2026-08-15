import Foundation
import GRDB

public enum MailboxFilter: Hashable, Sendable {
    case unified
    case important
    case newsletters
    case updates
    case other
    case open
    case sent
    case drafts
    case archived
    case blocked
    case spam
    case account(String)

    public var title: String {
        switch self {
        case .unified: return "Unified"
        case .important: return "Important"
        case .newsletters: return "Newsletters"
        case .updates: return "Updates"
        case .other: return "Other"
        case .open: return "Open"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .archived: return "Archived"
        case .blocked: return "Blocked"
        case .spam: return "Spam"
        case .account: return "Inbox"
        }
    }

    /// Threads for this mailbox, newest first. Unified views (including the
    /// split tabs) skip accounts excluded from the unified inbox.
    public func fetch(_ db: Database, limit: Int = 300) throws -> [MailThread] {
        let unifiedJoin = """
            FROM thread t
            JOIN account a ON a.id = t.accountId AND a.includeInUnified = 1
            JOIN thread_label tl ON tl.accountId = t.accountId AND tl.threadId = t.id AND tl.labelId = ?
            """
        let plainJoin = """
            FROM thread t
            JOIN thread_label tl ON tl.accountId = t.accountId AND tl.threadId = t.id AND tl.labelId = ?
            """
        let order = "ORDER BY t.lastDate DESC LIMIT \(limit)"
        switch self {
        case .unified:
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(unifiedJoin) WHERE t.isOpen = 0 \(order)",
                                           arguments: [GmailLabels.inbox])
        case .important, .newsletters, .updates, .other:
            let cat: String = {
                switch self {
                case .important: return "important"
                case .newsletters: return "newsletters"
                case .updates: return "updates"
                default: return "other"
                }
            }()
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* \(unifiedJoin) WHERE t.category = ? AND t.isOpen = 0 \(order)",
                arguments: [GmailLabels.inbox, cat])
        case .open:
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* FROM thread t WHERE t.isOpen = 1 \(order)")
        case .sent:
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(plainJoin) \(order)",
                                           arguments: [GmailLabels.sent])
        case .drafts:
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(plainJoin) \(order)",
                                           arguments: [GmailLabels.draft])
        case .archived:
            // Gmail's "All Mail minus Inbox": anything out of the inbox that
            // isn't trashed, spam, or an unsent draft. Sent threads you've
            // since archived belong here too, which is usually what you're
            // hunting for after hitting `e`.
            return try MailThread.fetchAll(db, sql: """
                SELECT t.* FROM thread t
                WHERE NOT EXISTS (
                    SELECT 1 FROM thread_label x
                    WHERE x.accountId = t.accountId AND x.threadId = t.id
                      AND x.labelId IN (?, ?, ?, ?)
                )
                AND t.isOpen = 0
                \(order)
                """, arguments: [GmailLabels.inbox, GmailLabels.trash,
                                 GmailLabels.spam, GmailLabels.draft])
        case .blocked:
            // Everything a block rule matches, wherever it ended up — blocked
            // mail is archived on arrival, so this is the only place it can be
            // seen as a group, and the only way to tell a rule that's doing
            // its job from one that's eating mail you wanted.
            //
            // Driven from `message` rather than a correlated EXISTS per
            // thread: the latter re-runs the rule match for every thread in
            // the database.
            return try MailThread.fetchAll(db, sql: """
                SELECT t.* FROM thread t
                JOIN (
                    SELECT DISTINCT m.accountId, m.threadId
                    FROM message m
                    JOIN blocked b
                      ON (b.kind = 'email' AND lower(m.fromEmail) = b.pattern)
                      OR (b.kind = 'domain' AND lower(m.fromEmail) LIKE '%@' || b.pattern)
                ) f ON f.accountId = t.accountId AND f.threadId = t.id
                \(order)
                """)
        case .spam:
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(plainJoin) \(order)",
                                           arguments: [GmailLabels.spam])
        case .account(let id):
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* \(plainJoin) WHERE t.accountId = ? AND t.isOpen = 0 \(order)",
                arguments: [GmailLabels.inbox, id])
        }
    }
}

public enum MailSearch {
    /// "foo bar" → "\"foo\"* \"bar\"*" (prefix-match every term, implicit AND)
    public static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Threads matching an FTS5 query, newest first.
    ///
    /// Drives from the FTS index rather than a correlated `EXISTS` against
    /// `thread`: the latter makes SQLite scan every thread and re-run MATCH
    /// per row, which never finishes on a large mailbox.
    ///
    /// The index is contentless and keyed by `message.rowid`, so the hit
    /// list joins through `message` to reach the thread.
    public static func threads(_ db: Database, match: String, limit: Int = 200) throws -> [MailThread] {
        try MailThread.fetchAll(db, sql: """
            SELECT t.* FROM thread t
            JOIN (
                SELECT DISTINCT m.accountId, m.threadId
                FROM message_fts
                JOIN message m ON m.rowid = message_fts.rowid
                WHERE message_fts MATCH ?
            ) f ON f.accountId = t.accountId AND f.threadId = t.id
            ORDER BY t.lastDate DESC LIMIT \(limit)
            """, arguments: [match])
    }
}
