import Foundation
import GRDB

public struct Account: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "account"
    public var id: String            // UUID string
    public var email: String
    public var displayName: String
    public var historyId: String?    // last synced Gmail historyId
    public var lastSyncAt: Date?
    public var sortOrder: Int
    public var backfillDone: Bool

    public init(id: String = UUID().uuidString, email: String, displayName: String = "",
                historyId: String? = nil, lastSyncAt: Date? = nil, sortOrder: Int = 0,
                backfillDone: Bool = false) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.historyId = historyId
        self.lastSyncAt = lastSyncAt
        self.sortOrder = sortOrder
        self.backfillDone = backfillDone
    }
}

public struct MailThread: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thread"
    public var accountId: String
    public var id: String            // Gmail thread id
    public var subject: String
    public var snippet: String
    public var lastDate: Date
    public var isUnread: Bool
    public var isStarred: Bool
    public var participants: String  // display string, e.g. "Alice, Bob"
    public var messageCount: Int
    public var category: String      // "important" | "newsletters" | "updates" | "other"

    // Unique key for SwiftUI lists across accounts
    public var key: String { accountId + "/" + id }
}

public struct Message: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"
    public var accountId: String
    public var id: String            // Gmail message id
    public var threadId: String
    public var fromName: String
    public var fromEmail: String
    public var toList: String        // comma-joined
    public var ccList: String
    public var date: Date
    public var snippet: String
    public var bodyHTML: String?
    public var bodyText: String?
    public var isUnread: Bool
    public var messageIdHeader: String   // RFC 822 Message-ID, for replies
    public var referencesHeader: String

    public var key: String { accountId + "/" + id }
}

public struct ThreadLabel: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thread_label"
    public var accountId: String
    public var threadId: String
    public var labelId: String
}

public struct OutboxItem: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "outbox"
    public var id: String            // UUID
    public var accountId: String
    public var threadId: String?     // reply target
    public var toList: String
    public var ccList: String
    public var bccList: String
    public var subject: String
    public var bodyText: String
    public var inReplyTo: String     // Message-ID header of replied-to message ("" if new)
    public var references: String
    public var sendAt: Date
    public var state: String         // "scheduled" | "sending" | "failed"
    public var lastError: String?

    public init(id: String = UUID().uuidString, accountId: String, threadId: String?,
                toList: String, ccList: String, bccList: String, subject: String,
                bodyText: String, inReplyTo: String = "", references: String = "",
                sendAt: Date, state: String = "scheduled", lastError: String? = nil) {
        self.id = id
        self.accountId = accountId
        self.threadId = threadId
        self.toList = toList
        self.ccList = ccList
        self.bccList = bccList
        self.subject = subject
        self.bodyText = bodyText
        self.inReplyTo = inReplyTo
        self.references = references
        self.sendAt = sendAt
        self.state = state
        self.lastError = lastError
    }
}

/// A queued local mutation to replay against Gmail (archive, read, star…).
public struct PendingOp: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pending_op"
    public var id: Int64?
    public var accountId: String
    public var threadId: String
    public var addLabelIds: String    // comma-joined Gmail label ids
    public var removeLabelIds: String
    public var createdAt: Date
    public var attempts: Int

    public init(id: Int64? = nil, accountId: String, threadId: String,
                addLabelIds: [String], removeLabelIds: [String],
                createdAt: Date = Date(), attempts: Int = 0) {
        self.id = id
        self.accountId = accountId
        self.threadId = threadId
        self.addLabelIds = addLabelIds.joined(separator: ",")
        self.removeLabelIds = removeLabelIds.joined(separator: ",")
        self.createdAt = createdAt
        self.attempts = attempts
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum GmailLabels {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let starred = "STARRED"
    public static let sent = "SENT"
    public static let trash = "TRASH"
    public static let spam = "SPAM"
    public static let important = "IMPORTANT"
    public static let categoryPersonal = "CATEGORY_PERSONAL"
    public static let categorySocial = "CATEGORY_SOCIAL"
    public static let categoryPromotions = "CATEGORY_PROMOTIONS"
    public static let categoryUpdates = "CATEGORY_UPDATES"
    public static let categoryForums = "CATEGORY_FORUMS"
}
