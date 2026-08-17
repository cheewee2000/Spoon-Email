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
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("Spoon", isDirectory: true)
        // Installs from before the rename keep their mailbox — move it over.
        let legacy = support.appendingPathComponent("SuperDuperHuman", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            // WAL + synchronous=NORMAL: a commit no longer waits on an fsync,
            // which is what sync does thousands of times. Durable against a
            // crash; only a power cut can cost the last few transactions,
            // and every one of those is re-fetchable from Gmail.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: dir.appendingPathComponent("mail.sqlite").path,
                                    configuration: config)
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
        m.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN includeInUnified BOOLEAN NOT NULL DEFAULT 1")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN listUnsubscribe TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN listUnsubscribePost TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE message ADD COLUMN isDraft BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE thread ADD COLUMN hasDraft BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE thread ADD COLUMN hasAttachments BOOLEAN NOT NULL DEFAULT 0")
            try db.create(table: "blocked") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pattern", .text).notNull().unique()   // email or bare domain, lowercase
                t.column("kind", .text).notNull()               // "email" | "domain"
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "attachment") { t in
                t.column("accountId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("partId", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
                t.primaryKey(["accountId", "messageId", "partId"])
            }
        }
        m.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE outbox ADD COLUMN quotedText TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE outbox ADD COLUMN quotedHTML TEXT")
            try db.execute(sql: "ALTER TABLE outbox ADD COLUMN draftMessageId TEXT NOT NULL DEFAULT ''")
        }
        m.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN backfillPageToken TEXT")
            // Old builds only backfilled 90 days / 500 threads and then set
            // backfillDone. Reopen backfill so the full history gets pulled;
            // existing threads just re-upsert as pages reach them.
            try db.execute(sql: "UPDATE account SET backfillDone = 0")
        }
        m.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN openLabelId TEXT")
            try db.execute(sql: "ALTER TABLE thread ADD COLUMN isOpen BOOLEAN NOT NULL DEFAULT 0")
        }
        m.registerMigration("v6") { db in
            try db.execute(sql: "ALTER TABLE outbox ADD COLUMN bodyHTML TEXT NOT NULL DEFAULT ''")
        }
        m.registerMigration("v7") { db in
            // JSON array of ComposeAttachment (inline images, base64 bytes).
            try db.execute(sql: "ALTER TABLE outbox ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'")
            // Lets a reopened draft match its `cid:` image refs to real parts.
            try db.execute(sql: "ALTER TABLE attachment ADD COLUMN contentId TEXT NOT NULL DEFAULT ''")
        }
        m.registerMigration("v8") { db in
            // The old index filtered on UNINDEXED fts5 columns, so every
            // delete was a full scan of the whole index — 130ms measured at
            // 126k messages, paid once per message plus once per thread on
            // every store. Keying rows by `message.rowid` makes a delete a
            // rowid lookup. Contentless as well: nothing reads the columns
            // back (search joins through to `message`), and the duplicate
            // copy of every body was ~460MB of the file.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts_v2 USING fts5(
                    subject, sender, recipients, body,
                    content='', contentless_delete=1
                )
                """)
            try db.execute(sql: """
                INSERT INTO message_fts_v2 (rowid, subject, sender, recipients, body)
                SELECT m.rowid, f.subject, f.sender, f.recipients, f.body
                FROM message_fts f
                JOIN message m ON m.accountId = f.accountId AND m.id = f.messageId
                """)
            try db.execute(sql: "DROP TABLE message_fts")
            try db.execute(sql: "ALTER TABLE message_fts_v2 RENAME TO message_fts")

            // The sidebar badge re-counts on every write; without this it
            // scanned all 93k thread rows each time.
            try db.execute(sql: """
                CREATE INDEX index_thread_on_open_unread ON thread(isOpen) WHERE isUnread = 1
                """)

            // Fingerprint of the thread as last stored, so a re-sync that
            // finds nothing changed can skip the write entirely instead of
            // rewriting every message body and re-indexing them.
            try db.execute(sql: "ALTER TABLE thread ADD COLUMN syncSig TEXT NOT NULL DEFAULT ''")

            // Recipient autocomplete used to LIKE-scan every message (144ms
            // per keystroke). Senders are a few thousand rows, kept current
            // as mail is stored.
            try db.create(table: "contact") { t in
                t.primaryKey("email", .text)      // lowercased
                t.column("name", .text).notNull()
                t.column("lastSeen", .datetime).notNull()
            }
            // Bare fromName is the one from the MAX(date) row — guaranteed
            // by SQLite for a min/max aggregate.
            try db.execute(sql: """
                INSERT INTO contact (email, name, lastSeen)
                SELECT lower(fromEmail), fromName, MAX(date) FROM message
                WHERE fromEmail <> '' GROUP BY lower(fromEmail)
                """)
        }
        m.registerMigration("v9") { db in
            // `attachment.contentId` was added to the v7 migration after v7
            // had already run here: the identifier was recorded, so the ALTER
            // never happened, and every attachment row then failed to decode.
            // That took out the whole thread-detail observation — any thread
            // with an attachment rendered a subject and an empty pane.
            if try !db.columns(in: "attachment").contains(where: { $0.name == "contentId" }) {
                try db.execute(sql: "ALTER TABLE attachment ADD COLUMN contentId TEXT NOT NULL DEFAULT ''")
            }
        }
        m.registerMigration("v10") { db in
            // Attachments stored before v9 landed have no Content-ID, so the
            // `cid:` image references in those bodies can't resolve. Flag the
            // threads that actually reference one — `repairInlineImagesPass`
            // re-fetches them in the background and clears the flag as it goes.
            // Default 1: rows written from here on are already correct, and
            // MailThread doesn't encode this column, so inserts take the
            // default and updates leave it alone.
            try db.execute(sql: "ALTER TABLE thread ADD COLUMN cidRepaired BOOLEAN NOT NULL DEFAULT 1")
            try db.execute(sql: """
                UPDATE thread SET cidRepaired = 0
                WHERE EXISTS (
                    SELECT 1 FROM message m
                    WHERE m.accountId = thread.accountId AND m.threadId = thread.id
                      AND m.bodyHTML LIKE '%cid:%'
                )
                """)
        }
        m.registerMigration("v11") { db in
            // Inline images with an empty filename were skipped entirely when
            // a thread was stored, so those parts have no attachment row at
            // all — a `cid:` reference to one still dead-ends even on threads
            // the v10 pass already "repaired". Flag them again; the same
            // background pass re-fetches and now keeps the nameless parts.
            try db.execute(sql: """
                UPDATE thread SET cidRepaired = 0
                WHERE EXISTS (
                    SELECT 1 FROM message m
                    WHERE m.accountId = thread.accountId AND m.threadId = thread.id
                      AND m.bodyHTML LIKE '%cid:%'
                )
                """)
        }
        m.registerMigration("v12") { db in
            // Per-account color, picked by hand. NULL keeps the account on the
            // built-in palette, which is where every existing one starts.
            try db.execute(sql: "ALTER TABLE account ADD COLUMN colorHex TEXT")
            // Avatars are looked up by address, and the thread row only kept
            // participants as a display string. Backfill from the messages
            // already stored so the pictures show up without waiting for
            // every thread to be re-synced.
            try db.execute(sql: "ALTER TABLE thread ADD COLUMN lastSenderEmail TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: """
                UPDATE thread SET lastSenderEmail = COALESCE((
                    SELECT m.fromEmail FROM message m
                    WHERE m.accountId = thread.accountId AND m.threadId = thread.id
                    ORDER BY m.date DESC LIMIT 1
                ), '')
                """)
        }
        m.registerMigration("v13") { db in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN spamSynced BOOLEAN NOT NULL DEFAULT 0")
        }
        m.registerMigration("v14") { db in
            // The inbox lists re-run on every commit, and a sync pass commits
            // once per thread. Each run walked all ~44k INBOX label rows,
            // joined, and sorted them (33ms) to keep 300. A denormalized flag
            // on the thread row plus partial indexes turns that into an index
            // walk that stops at 300. Triggers keep the flag right through
            // every write path (sync store, optimistic modify, draft cleanup)
            // without any of them having to know it exists; MailThread doesn't
            // encode the column, so record saves leave it alone.
            try db.execute(sql: "ALTER TABLE thread ADD COLUMN isInbox BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: """
                UPDATE thread SET isInbox = 1 WHERE EXISTS (
                    SELECT 1 FROM thread_label tl
                    WHERE tl.accountId = thread.accountId AND tl.threadId = thread.id AND tl.labelId = 'INBOX'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER thread_label_inbox_insert AFTER INSERT ON thread_label
                WHEN NEW.labelId = 'INBOX'
                BEGIN
                    UPDATE thread SET isInbox = 1
                    WHERE accountId = NEW.accountId AND id = NEW.threadId AND isInbox = 0;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER thread_label_inbox_delete AFTER DELETE ON thread_label
                WHEN OLD.labelId = 'INBOX'
                BEGIN
                    UPDATE thread SET isInbox = 0
                    WHERE accountId = OLD.accountId AND id = OLD.threadId AND isInbox = 1;
                END
                """)
            try db.execute(sql: "CREATE INDEX index_thread_inbox_date ON thread(lastDate) WHERE isInbox = 1")
            try db.execute(sql: "CREATE INDEX index_thread_inbox_category_date ON thread(category, lastDate) WHERE isInbox = 1")
            try db.execute(sql: "CREATE INDEX index_thread_inbox_account_date ON thread(accountId, lastDate) WHERE isInbox = 1")
        }
        return m
    }
}
