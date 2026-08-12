import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: DatabaseWriter

    public init(_ writer: DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// Opens the on-disk database in Application Support.
    public static func open() throws -> AppDatabase {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("SuperDuperHuman", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("mail.sqlite").path)
        return try AppDatabase(pool)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("email", .text).notNull().unique()
                t.column("displayName", .text).notNull()
                t.column("historyId", .text)
                t.column("lastSyncAt", .datetime)
                t.column("sortOrder", .integer).notNull()
                t.column("backfillDone", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "thread") { t in
                t.column("accountId", .text).notNull().references("account", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("snippet", .text).notNull()
                t.column("lastDate", .datetime).notNull()
                t.column("isUnread", .boolean).notNull()
                t.column("isStarred", .boolean).notNull()
                t.column("participants", .text).notNull()
                t.column("messageCount", .integer).notNull()
                t.column("category", .text).notNull().defaults(to: "important")
                t.primaryKey(["accountId", "id"])
            }
            try db.create(indexOn: "thread", columns: ["lastDate"])
            try db.create(table: "message") { t in
                t.column("accountId", .text).notNull().references("account", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("threadId", .text).notNull()
                t.column("fromName", .text).notNull()
                t.column("fromEmail", .text).notNull()
                t.column("toList", .text).notNull()
                t.column("ccList", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("snippet", .text).notNull()
                t.column("bodyHTML", .text)
                t.column("bodyText", .text)
                t.column("isUnread", .boolean).notNull()
                t.column("messageIdHeader", .text).notNull()
                t.column("referencesHeader", .text).notNull()
                t.primaryKey(["accountId", "id"])
            }
            try db.create(indexOn: "message", columns: ["accountId", "threadId"])
            try db.create(table: "thread_label") { t in
                t.column("accountId", .text).notNull()
                t.column("threadId", .text).notNull()
                t.column("labelId", .text).notNull()
                t.primaryKey(["accountId", "threadId", "labelId"])
            }
            try db.create(indexOn: "thread_label", columns: ["labelId"])
            try db.create(table: "pending_op") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                t.column("threadId", .text).notNull()
                t.column("addLabelIds", .text).notNull()
                t.column("removeLabelIds", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("attempts", .integer).notNull()
            }
            try db.create(table: "outbox") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                t.column("threadId", .text)
                t.column("toList", .text).notNull()
                t.column("ccList", .text).notNull()
                t.column("bccList", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("bodyText", .text).notNull()
                t.column("inReplyTo", .text).notNull()
                t.column("references", .text).notNull()
                t.column("sendAt", .datetime).notNull()
                t.column("state", .text).notNull()
                t.column("lastError", .text)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    accountId UNINDEXED, messageId UNINDEXED, threadId UNINDEXED,
                    subject, sender, recipients, body
                )
                """)
        }
        return m
    }
}
