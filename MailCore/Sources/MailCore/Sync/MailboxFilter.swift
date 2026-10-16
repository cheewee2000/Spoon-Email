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
        // Inbox membership is the denormalized `thread.isInbox` (kept by
        // triggers on thread_label; see migration v14) so these walk a
        // partial index newest-first instead of joining the label table.
        // The account filter is an IN-subquery, not a join: with it the
        // planner runs the (accountId, lastDate) index once per included
        // account, so an excluded account's 40k inbox threads never get
        // touched (<1ms vs 11ms for the join form).
        let unifiedJoin = """
            FROM thread t
            """
        let unifiedWhere = "t.isInbox = 1 AND t.accountId IN (SELECT id FROM account WHERE includeInUnified = 1)"
        let plainJoin = """
            FROM thread t
            JOIN thread_label tl ON tl.accountId = t.accountId AND tl.threadId = t.id AND tl.labelId = ?
            """
        let order = "ORDER BY t.lastDate DESC LIMIT \(limit)"
        switch self {
        case .unified:
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* \(unifiedJoin) WHERE \(unifiedWhere) AND t.isOpen = 0 \(order)")
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
                db, sql: "SELECT t.* \(unifiedJoin) WHERE \(unifiedWhere) AND t.category = ? AND t.isOpen = 0 \(order)",
                arguments: [cat])
        case .open:
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* FROM thread t WHERE t.isOpen = 1 \(order)")
        case .sent:
            // EXISTS, not the join: SENT is on 150k+ threads, and joining
            // them all just to sort by lastDate cost 400ms (2s cold) on every
            // commit. Walking threads newest-first and probing the label
            // stops after `limit` hits in ~10ms. Drafts and spam keep the
            // join — those labels are sparse, so the join side is tiny.
            return try MailThread.fetchAll(db, sql: """
                SELECT t.* FROM thread t
                WHERE EXISTS (
                    SELECT 1 FROM thread_label x
                    WHERE x.accountId = t.accountId AND x.threadId = t.id AND x.labelId = ?
                )
                \(order)
                """, arguments: [GmailLabels.sent])
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
            // its job from one that's eating mail you wanted. `isBlocked` is
            // kept by the sync engine (migration v16), so this is an index walk.
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* FROM thread t WHERE t.isBlocked = 1 \(order)")
        case .spam:
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(plainJoin) \(order)",
                                           arguments: [GmailLabels.spam])
        case .account(let id):
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* FROM thread t WHERE t.isInbox = 1 AND t.accountId = ? AND t.isOpen = 0 \(order)",
                arguments: [id])
        }
    }
}

public enum MailSearch {
    /// Gmail-style field operators → FTS5 column names.
    static let operators = [("from:", "sender"), ("to:", "recipients"), ("subject:", "subject")]

    /// "sarah vacuum form" → "\"sarah\"* \"vacuum\"* \"form\"*" (prefix-match
    /// every term, implicit AND). `from:sarah` / `to:sarah` / `subject:x`
    /// pin a term to that one field: `sender: "sarah"*`.
    public static func ftsQuery(_ raw: String) -> String? {
        let terms: [String] = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap { token in
                var word = token
                var column: String?
                for (op, col) in operators where word.lowercased().hasPrefix(op) {
                    column = col
                    word = String(word.dropFirst(op.count))
                }
                word = word.replacingOccurrences(of: "\"", with: "")
                guard !word.isEmpty else { return nil }
                let term = "\"\(word)\"*"
                return column.map { "\($0): \(term)" } ?? term
            }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " ")
    }

    /// Threads matching an FTS5 query, best match first (ties newest first).
    ///
    /// Drives from the FTS index rather than a correlated `EXISTS` against
    /// `thread`: the latter makes SQLite scan every thread and re-run MATCH
    /// per row, which never finishes on a large mailbox.
    ///
    /// Ranking is bm25 with a hit in subject/sender/recipients weighted well
    /// above one in the body, so a thread *with* Sarah outranks a newsletter
    /// that merely mentions a Sarah. The inner `ORDER BY rank LIMIT` is what
    /// lets bm25() run at all: without it the planner probes the index by
    /// rowid from the `message` side and refuses the function. A thread's
    /// rank is its best message's.
    ///
    /// The index is contentless and keyed by `message.rowid`, so the hit
    /// list joins through `message` to reach the thread.
    public static func threads(_ db: Database, match: String, limit: Int = 200) throws -> [MailThread] {
        try MailThread.fetchAll(db, sql: """
            SELECT t.* FROM thread t
            JOIN (
                SELECT m.accountId, m.threadId, MIN(h.rank) AS rank
                FROM (SELECT rowid AS rid, bm25(message_fts, 4.0, 8.0, 8.0, 1.0) AS rank
                      FROM message_fts WHERE message_fts MATCH ?
                      ORDER BY rank LIMIT 2000) h
                JOIN message m ON m.rowid = h.rid
                GROUP BY m.accountId, m.threadId
            ) f ON f.accountId = t.accountId AND f.threadId = t.id
            ORDER BY f.rank, t.lastDate DESC LIMIT \(limit)
            """, arguments: [match])
    }
}
