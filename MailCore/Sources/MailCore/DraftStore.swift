import Foundation
import GRDB

public extension AppDatabase {
    /// Removes a draft message from the local cache and repairs its thread's
    /// draft state (DRAFT badge, Drafts mailbox row, orphan thread shell).
    ///
    /// Call this once the draft is gone from Gmail — after it was discarded,
    /// or after the send that replaced it. Gmail's history feed doesn't
    /// reliably report draft deletions, so waiting for sync to notice can
    /// leave the message showing as a draft indefinitely.
    func purgeDraft(accountId: String, messageId: String) async throws {
        _ = try await writer.write { db in
            let threadId = try String.fetchOne(
                db, sql: "SELECT threadId FROM message WHERE accountId = ? AND id = ?",
                arguments: [accountId, messageId])
            // Index first — it's keyed by the message row's own rowid.
            try db.execute(sql: """
                DELETE FROM message_fts WHERE rowid IN (
                    SELECT rowid FROM message WHERE accountId = ? AND id = ?
                )
                """, arguments: [accountId, messageId])
            try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND id = ?",
                           arguments: [accountId, messageId])
            guard let threadId else { return }
            let remaining = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM message WHERE accountId = ? AND threadId = ?",
                arguments: [accountId, threadId]) ?? 0
            if remaining == 0 {
                // The draft was the whole thread — drop the shell.
                try db.execute(sql: "DELETE FROM thread WHERE accountId = ? AND id = ?",
                               arguments: [accountId, threadId])
                try db.execute(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ?",
                               arguments: [accountId, threadId])
            } else {
                try db.execute(sql: """
                    UPDATE thread SET
                        hasDraft = EXISTS(SELECT 1 FROM message
                            WHERE accountId = ? AND threadId = ? AND isDraft = 1),
                        messageCount = ?
                    WHERE accountId = ? AND id = ?
                    """, arguments: [accountId, threadId, remaining, accountId, threadId])
                // The Drafts mailbox lists threads by this label row.
                try db.execute(sql: """
                    DELETE FROM thread_label
                    WHERE accountId = ? AND threadId = ? AND labelId = 'DRAFT'
                      AND NOT EXISTS (SELECT 1 FROM message
                          WHERE accountId = ? AND threadId = ? AND isDraft = 1)
                    """, arguments: [accountId, threadId, accountId, threadId])
            }
        }
    }
}
