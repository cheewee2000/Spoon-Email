import Foundation
import GRDB

public actor SyncEngine {
    private let db: AppDatabase
    private let tokens: TokenManager
    private var syncingAccounts: Set<String> = []

    /// UI status line ("Syncing 3 accounts…"); nil when idle.
    public var statusHandler: (@Sendable (String?) -> Void)?
    public func setStatusHandler(_ h: @Sendable @escaping (String?) -> Void) { statusHandler = h }

    public init(db: AppDatabase, tokens: TokenManager) {
        self.db = db
        self.tokens = tokens
    }

    // MARK: - Top level

    public func syncAll(accounts: [Account]) async {
        for account in accounts where !syncingAccounts.contains(account.id) {
            syncingAccounts.insert(account.id)
            defer { syncingAccounts.remove(account.id) }
            do {
                statusHandler?("Syncing \(account.email)…")
                try await replayPendingOps(accountId: account.id)
                if account.backfillDone {
                    try await incrementalSync(account: account)
                } else {
                    try await backfill(account: account)
                }
            } catch {
                statusHandler?("Sync failed: \(account.email)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        statusHandler?(nil)
    }

    // MARK: - Backfill

    static let backfillThreadLimit = 500

    private func backfill(account: Account) async throws {
        let client = GmailClient(accountId: account.id, tokens: tokens)
        let baselineHistoryId = try await client.profile().historyId

        var stubs: [GThreadStub] = []
        var pageToken: String?
        repeat {
            let page = try await client.listThreads(q: "newer_than:90d", pageToken: pageToken)
            stubs.append(contentsOf: page.threads ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil && stubs.count < Self.backfillThreadLimit

        var done = 0
        try await withThrowingTaskGroup(of: GThread?.self) { group in
            var iterator = stubs.prefix(Self.backfillThreadLimit).makeIterator()
            var inFlight = 0
            func addNext(_ group: inout ThrowingTaskGroup<GThread?, Error>) {
                if let stub = iterator.next() {
                    group.addTask {
                        try? await client.getThread(stub.id)
                    }
                    inFlight += 1
                }
            }
            for _ in 0..<6 { addNext(&group) }
            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1
                if let gThread = result {
                    try await store(gThread: gThread, accountId: account.id)
                }
                done += 1
                if done % 25 == 0 {
                    statusHandler?("Syncing \(account.email)… \(done)/\(min(stubs.count, Self.backfillThreadLimit))")
                }
                addNext(&group)
            }
        }

        try await db.writer.write { [id = account.id] db in
            try db.execute(
                sql: "UPDATE account SET historyId = ?, backfillDone = 1, lastSyncAt = ? WHERE id = ?",
                arguments: [baselineHistoryId, Date(), id])
        }
    }

    // MARK: - Incremental

    private func incrementalSync(account: Account) async throws {
        guard let startId = account.historyId else {
            return try await backfill(account: account)
        }
        let client = GmailClient(accountId: account.id, tokens: tokens)

        var threadIds = Set<String>()
        var newHistoryId: String?
        var pageToken: String?
        do {
            repeat {
                let page = try await client.listHistory(startHistoryId: startId, pageToken: pageToken)
                newHistoryId = page.historyId ?? newHistoryId
                for h in page.history ?? [] {
                    (h.messagesAdded ?? []).forEach { threadIds.insert($0.message.threadId) }
                    (h.messagesDeleted ?? []).forEach { threadIds.insert($0.message.threadId) }
                    (h.labelsAdded ?? []).forEach { threadIds.insert($0.message.threadId) }
                    (h.labelsRemoved ?? []).forEach { threadIds.insert($0.message.threadId) }
                }
                pageToken = page.nextPageToken
            } while pageToken != nil
        } catch MailError.http(404, _) {
            // History expired — full re-backfill
            try await db.writer.write { [id = account.id] db in
                try db.execute(sql: "UPDATE account SET backfillDone = 0, historyId = NULL WHERE id = ?",
                               arguments: [id])
            }
            var reset = account
            reset.backfillDone = false
            reset.historyId = nil
            return try await backfill(account: reset)
        }

        for threadId in threadIds {
            do {
                let gThread = try await client.getThread(threadId)
                try await store(gThread: gThread, accountId: account.id)
            } catch MailError.http(404, _) {
                try await deleteLocalThread(accountId: account.id, threadId: threadId)
            }
        }

        if let newHistoryId {
            try await db.writer.write { [id = account.id] db in
                try db.execute(sql: "UPDATE account SET historyId = ?, lastSyncAt = ? WHERE id = ?",
                               arguments: [newHistoryId, Date(), id])
            }
        }
    }

    // MARK: - Storage

    func store(gThread: GThread, accountId: String) async throws {
        guard let gMessages = gThread.messages, !gMessages.isEmpty else { return }

        var labelSet = Set<String>()
        var messages: [Message] = []
        for g in gMessages {
            let (m, labels) = MimeParser.localMessage(from: g, accountId: accountId)
            messages.append(m)
            labelSet.formUnion(labels)
        }
        messages.sort { $0.date < $1.date }

        var participants: [String] = []
        for m in messages where !participants.contains(m.fromName) {
            participants.append(m.fromName)
        }

        let subject = MimeParser.decodeEntities(MimeParser.subject(of: gMessages[0]))
        let thread = MailThread(
            accountId: accountId,
            id: gThread.id,
            subject: subject.isEmpty ? "(no subject)" : subject,
            snippet: messages.last?.snippet ?? "",
            lastDate: messages.last?.date ?? Date(),
            isUnread: messages.contains { $0.isUnread },
            isStarred: labelSet.contains(GmailLabels.starred),
            participants: participants.joined(separator: ", "),
            messageCount: messages.count,
            category: ThreadCategory.derive(from: labelSet)
        )

        try await db.writer.write { db in
            try thread.save(db)
            try db.execute(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ?",
                           arguments: [accountId, gThread.id])
            for label in labelSet {
                try ThreadLabel(accountId: accountId, threadId: gThread.id, labelId: label).save(db)
            }
            for m in messages {
                try m.save(db)
                try Self.indexFTS(db: db, message: m)
            }
        }
    }

    static func indexFTS(db: Database, message m: Message) throws {
        try db.execute(sql: "DELETE FROM message_fts WHERE accountId = ? AND messageId = ?",
                       arguments: [m.accountId, m.id])
        var body = m.bodyText ?? MimeParser.stripHTML(m.bodyHTML ?? "")
        if body.count > 100_000 { body = String(body.prefix(100_000)) }
        try db.execute(
            sql: """
            INSERT INTO message_fts (accountId, messageId, threadId, subject, sender, recipients, body)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [m.accountId, m.id, m.threadId,
                        "", m.fromName + " " + m.fromEmail,
                        m.toList + " " + m.ccList, body])
    }

    func deleteLocalThread(accountId: String, threadId: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM thread WHERE accountId = ? AND id = ?",
                           arguments: [accountId, threadId])
            try db.execute(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ?",
                           arguments: [accountId, threadId])
            try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND threadId = ?",
                           arguments: [accountId, threadId])
            try db.execute(sql: "DELETE FROM message_fts WHERE accountId = ? AND threadId = ?",
                           arguments: [accountId, threadId])
        }
    }

    // MARK: - Optimistic mutations

    /// Applies a label change locally right away, queues it, and replays.
    public func modifyThread(accountId: String, threadId: String,
                             add: [String], remove: [String]) async {
        try? await db.writer.write { db in
            for label in add {
                try ThreadLabel(accountId: accountId, threadId: threadId, labelId: label).save(db)
            }
            for label in remove {
                try db.execute(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ? AND labelId = ?",
                               arguments: [accountId, threadId, label])
            }
            let labels = Set(try String.fetchAll(
                db, sql: "SELECT labelId FROM thread_label WHERE accountId = ? AND threadId = ?",
                arguments: [accountId, threadId]))
            try db.execute(
                sql: "UPDATE thread SET isUnread = ?, isStarred = ?, category = ? WHERE accountId = ? AND id = ?",
                arguments: [labels.contains(GmailLabels.unread),
                            labels.contains(GmailLabels.starred),
                            ThreadCategory.derive(from: labels),
                            accountId, threadId])
            if add.contains(GmailLabels.unread) || remove.contains(GmailLabels.unread) {
                try db.execute(sql: "UPDATE message SET isUnread = ? WHERE accountId = ? AND threadId = ?",
                               arguments: [add.contains(GmailLabels.unread), accountId, threadId])
            }
            var op = PendingOp(accountId: accountId, threadId: threadId,
                               addLabelIds: add, removeLabelIds: remove)
            try op.insert(db)
        }
        try? await replayPendingOps(accountId: accountId)
    }

    public func archive(accountId: String, threadId: String) async {
        await modifyThread(accountId: accountId, threadId: threadId,
                           add: [], remove: [GmailLabels.inbox])
    }

    public func markRead(accountId: String, threadId: String, read: Bool) async {
        await modifyThread(accountId: accountId, threadId: threadId,
                           add: read ? [] : [GmailLabels.unread],
                           remove: read ? [GmailLabels.unread] : [])
    }

    public func toggleStar(accountId: String, threadId: String, starred: Bool) async {
        await modifyThread(accountId: accountId, threadId: threadId,
                           add: starred ? [GmailLabels.starred] : [],
                           remove: starred ? [] : [GmailLabels.starred])
    }

    // MARK: - Pending-op replay

    func replayPendingOps(accountId: String) async throws {
        let ops = try await db.writer.read { db in
            try PendingOp
                .filter(Column("accountId") == accountId)
                .order(Column("id"))
                .fetchAll(db)
        }
        guard !ops.isEmpty else { return }
        let client = GmailClient(accountId: accountId, tokens: tokens)
        for op in ops {
            let add = op.addLabelIds.isEmpty ? [] : op.addLabelIds.components(separatedBy: ",")
            let remove = op.removeLabelIds.isEmpty ? [] : op.removeLabelIds.components(separatedBy: ",")
            do {
                try await client.modifyThread(op.threadId, add: add, remove: remove)
                _ = try await db.writer.write { db in try op.delete(db) }
            } catch MailError.http(let code, _) where (400...499).contains(code) {
                // Non-retryable (thread gone, label invalid) — drop the op
                _ = try? await db.writer.write { db in try op.delete(db) }
            } catch {
                // Network/server issue: bump attempts, retry on next sync
                _ = try? await db.writer.write { db in
                    try db.execute(sql: "UPDATE pending_op SET attempts = attempts + 1 WHERE id = ?",
                                   arguments: [op.id])
                }
                throw error
            }
        }
    }
}
