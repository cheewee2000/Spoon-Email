import Foundation
import GRDB

public enum MailboxFilter: Hashable, Sendable {
    case unified
    case important
    case newsletters
    case updates
    case other
    case sent
    case drafts
    case account(String)

    public var title: String {
        switch self {
        case .unified: return "Unified"
        case .important: return "Important"
        case .newsletters: return "Newsletters"
        case .updates: return "Updates"
        case .other: return "Other"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
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
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(unifiedJoin) \(order)",
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
                db, sql: "SELECT t.* \(unifiedJoin) WHERE t.category = ? \(order)",
                arguments: [GmailLabels.inbox, cat])
        case .sent:
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(plainJoin) \(order)",
                                           arguments: [GmailLabels.sent])
        case .drafts:
            return try MailThread.fetchAll(db, sql: "SELECT t.* \(plainJoin) \(order)",
                                           arguments: [GmailLabels.draft])
        case .account(let id):
            return try MailThread.fetchAll(
                db, sql: "SELECT t.* \(plainJoin) WHERE t.accountId = ? \(order)",
                arguments: [GmailLabels.inbox, id])
        }
    }
}
