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
    public var includeInUnified: Bool
    public var backfillPageToken: String?  // resume point while walking the full history
    public var openLabelId: String?        // Gmail label id of this account's "Open" label
    /// The color this account wears through the app, as "#RRGGBB". Unset
    /// means the account takes its slot in the built-in palette instead.
    public var colorHex: String?

    public init(id: String = UUID().uuidString, email: String, displayName: String = "",
                historyId: String? = nil, lastSyncAt: Date? = nil, sortOrder: Int = 0,
                backfillDone: Bool = false, includeInUnified: Bool = true,
                backfillPageToken: String? = nil, openLabelId: String? = nil,
                colorHex: String? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.historyId = historyId
        self.lastSyncAt = lastSyncAt
        self.sortOrder = sortOrder
        self.backfillDone = backfillDone
        self.includeInUnified = includeInUnified
        self.backfillPageToken = backfillPageToken
        self.openLabelId = openLabelId
        self.colorHex = colorHex
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
    public var hasDraft: Bool
    public var hasAttachments: Bool
    public var isOpen: Bool = false  // carries the account's "Open" label (awaiting reply / act later)
    /// Who the newest message came from. The list only stores participants as
    /// a display string, and an avatar has to be looked up by address.
    public var lastSenderEmail: String = ""

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
    public var listUnsubscribe: String       // raw List-Unsubscribe header ("" if none)
    public var listUnsubscribePost: String   // raw List-Unsubscribe-Post header
    public var isDraft: Bool

    public var key: String { accountId + "/" + id }
}

public struct Attachment: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"
    public var accountId: String
    public var messageId: String
    public var partId: String     // stable part id within the message
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentId: String  // Content-ID without <>, "" when not inline

    public init(accountId: String, messageId: String, partId: String,
                filename: String, mimeType: String, size: Int, contentId: String = "") {
        self.accountId = accountId
        self.messageId = messageId
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentId = contentId
    }
}

public struct BlockRule: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "blocked"
    public var id: Int64?
    public var pattern: String   // "spam@foo.com" or "foo.com"
    public var kind: String      // "email" | "domain"
    public var createdAt: Date

    public init(id: Int64? = nil, pattern: String, kind: String, createdAt: Date = Date()) {
        self.id = id
        self.pattern = pattern
        self.kind = kind
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public func matches(email: String) -> Bool {
        let e = email.lowercased()
        return kind == "email" ? e == pattern : e.hasSuffix("@" + pattern)
    }
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
    public var bodyHTML: String      // rich version of what was typed ("" = plain text only)
    public var quotedText: String    // plain-text version of the quoted/forwarded trail
    public var quotedHTML: String?   // original HTML of the quoted/forwarded trail
    public var attachments: [ComposeAttachment]  // stored as JSON; inline images live here
    public var inReplyTo: String     // Message-ID header of replied-to message ("" if new)
    public var references: String
    public var draftMessageId: String // Gmail message id of a draft this send replaces ("" if none)
    public var sendAt: Date
    public var state: String         // "scheduled" | "sending" | "failed"
    public var lastError: String?

    public init(id: String = UUID().uuidString, accountId: String, threadId: String?,
                toList: String, ccList: String, bccList: String, subject: String,
                bodyText: String, bodyHTML: String = "",
                quotedText: String = "", quotedHTML: String? = nil,
                attachments: [ComposeAttachment] = [],
                inReplyTo: String = "", references: String = "", draftMessageId: String = "",
                sendAt: Date, state: String = "scheduled", lastError: String? = nil) {
        self.id = id
        self.accountId = accountId
        self.threadId = threadId
        self.toList = toList
        self.ccList = ccList
        self.bccList = bccList
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.quotedText = quotedText
        self.quotedHTML = quotedHTML
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.draftMessageId = draftMessageId
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
    public static let draft = "DRAFT"
    public static let trash = "TRASH"
    public static let spam = "SPAM"
    public static let important = "IMPORTANT"
    public static let categoryPersonal = "CATEGORY_PERSONAL"
    public static let categorySocial = "CATEGORY_SOCIAL"
    public static let categoryPromotions = "CATEGORY_PROMOTIONS"
    public static let categoryUpdates = "CATEGORY_UPDATES"
    public static let categoryForums = "CATEGORY_FORUMS"
}
