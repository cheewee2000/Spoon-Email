import Foundation
import GRDB

/// Identifies one thread across accounts.
public struct ThreadRef: Sendable, Hashable {
    public let accountId: String
    public let threadId: String
    public init(accountId: String, threadId: String) {
        self.accountId = accountId
        self.threadId = threadId
    }
}

/// An inbound message that just landed — enough to raise a banner without
/// going back to the database.
public struct NewMail: Sendable, Hashable {
    public let accountId: String
    public let threadId: String
    public let messageId: String
    public let fromName: String
    public let fromEmail: String
    public let subject: String
    public let snippet: String
}

public actor SyncEngine {
    private let db: AppDatabase
    private let tokens: TokenManager
    private var syncingAccounts: Set<String> = []
    private var backfillingAccounts: Set<String> = []

    /// UI status line ("Syncing 3 accounts…"); nil when idle.
    public var statusHandler: (@Sendable (String?) -> Void)?
    public func setStatusHandler(_ h: @Sendable @escaping (String?) -> Void) { statusHandler = h }

    /// Fires once per incremental pass with everything that arrived in it.
    /// Batched rather than per-message so a long offline gap raises one
    /// summary instead of fifty banners.
    public var newMailHandler: (@Sendable ([NewMail]) -> Void)?
    public func setNewMailHandler(_ h: @Sendable @escaping ([NewMail]) -> Void) { newMailHandler = h }

    public init(db: AppDatabase, tokens: TokenManager) {
        self.db = db
        self.tokens = tokens
    }

    // MARK: - Top level

    /// Fresh mail: replay pending ops, then walk each account's history feed.
    /// Deliberately does NOT touch the backfill — a backfill chunk takes
    /// minutes, and letting it share this pass meant new mail waited behind
    /// years of old mail (and a manual refresh mid-chunk did nothing at all).
    public func syncAll(accounts: [Account]) async {
        for account in accounts where !syncingAccounts.contains(account.id) {
            syncingAccounts.insert(account.id)
            defer { syncingAccounts.remove(account.id) }
            do {
                statusHandler?("Syncing \(account.email)…")
                try await replayPendingOps(accountId: account.id)
                // The caller's Account may be a stale in-memory copy; sync
                // state (historyId, backfill progress) lives in the DB row.
                var acct = (try await db.writer.read { [id = account.id] db in
                    try Account.fetchOne(db, key: id)
                }) ?? account
                try await ensureOpenLabel(account: &acct)
                if acct.historyId == nil {
                    // First contact: pin the history baseline before backfill
                    // starts so nothing arriving during it is missed.
                    let client = GmailClient(accountId: acct.id, tokens: tokens)
                    let baseline = try await client.profile().historyId
                    try await db.writer.write { [id = acct.id] db in
                        try db.execute(sql: "UPDATE account SET historyId = ? WHERE id = ?",
                                       arguments: [baseline, id])
                    }
                    acct.historyId = baseline
                } else {
                    try await incrementalSync(account: acct)
                }
                await refreshDraftThreadsOnce(accountId: acct.id)
            } catch {
                statusHandler?("Sync failed: \(account.email)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        statusHandler?(nil)
    }

    /// One chunk of old mail per account, run on its own slow schedule. The
    /// actor is reentrant across awaits, so `syncAll` keeps interleaving with
    /// this and new mail lands while the archive is still filling in.
    public func backfillPass(accounts: [Account]) async {
        for account in accounts where !backfillingAccounts.contains(account.id) {
            let acct = ((try? await db.writer.read { [id = account.id] db in
                try Account.fetchOne(db, key: id)
            }) ?? nil) ?? account
            guard !acct.backfillDone || !acct.spamSynced else { continue }
            backfillingAccounts.insert(acct.id)
            defer { backfillingAccounts.remove(acct.id) }
            if !acct.spamSynced {
                try? await catchUpSpam(account: acct)
            }
            if !acct.backfillDone {
                try? await continueBackfill(account: acct)
            }
        }
    }

    /// One-time pull of the spam folder. `threads.list` leaves spam out
    /// unless asked, so backfill never brings it in; Gmail also purges spam
    /// after 30 days, so this is a page or two, not a second backfill.
    private func catchUpSpam(account: Account) async throws {
        let client = GmailClient(accountId: account.id, tokens: tokens)
        var pageToken: String? = nil
        repeat {
            let page = try await client.listThreads(labelIds: [GmailLabels.spam],
                                                    pageToken: pageToken,
                                                    includeSpamTrash: true)
            for stub in page.threads ?? [] {
                if let g = try? await client.getThread(stub.id) {
                    try await store(gThread: g, accountId: account.id)
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        try await db.writer.write { [id = account.id] db in
            try db.execute(sql: "UPDATE account SET spamSynced = 1 WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Inline-image repair (one-time, resumable)

    static let cidRepairChunk = 50

    private var cidRepairDone: Set<String> = []

    /// Threads synced before `attachment.contentId` existed kept no part id
    /// for their inline images, so every `cid:` reference in those bodies
    /// dead-ends. Re-fetch the affected threads a chunk at a time off the
    /// backfill loop; `thread.cidRepaired` records the progress, so this
    /// converges and stays done across launches.
    public func repairInlineImagesPass(accounts: [Account]) async {
        for account in accounts where !cidRepairDone.contains(account.id) {
            let threadIds = (try? await db.writer.read { [id = account.id] db in
                try String.fetchAll(db, sql: """
                    SELECT id FROM thread WHERE accountId = ? AND cidRepaired = 0
                    LIMIT \(Self.cidRepairChunk)
                    """, arguments: [id])
            }) ?? []
            guard !threadIds.isEmpty else {
                cidRepairDone.insert(account.id)
                continue
            }
            statusHandler?("Restoring inline images for \(account.email)…")
            let client = GmailClient(accountId: account.id, tokens: tokens)
            var failures = 0
            for threadId in threadIds {
                do {
                    let g = try await client.getThread(threadId)
                    // `store` skips a thread whose fingerprint matches — which
                    // is every thread here, since only the missing column
                    // changed. Clear it so the attachment rows get rewritten.
                    try await db.writer.write { [id = account.id] db in
                        try db.execute(sql: "UPDATE thread SET syncSig = '' WHERE accountId = ? AND id = ?",
                                       arguments: [id, threadId])
                    }
                    try await store(gThread: g, accountId: account.id)
                } catch MailError.http(404, _) {
                    try? await deleteLocalThread(accountId: account.id, threadId: threadId)
                } catch {
                    // Leave it flagged and try again next pass, but don't spin
                    // through the whole backlog while the network is down.
                    failures += 1
                    if failures >= 3 { break }
                    continue
                }
                try? await db.writer.write { [id = account.id] db in
                    try db.execute(sql: "UPDATE thread SET cidRepaired = 1 WHERE accountId = ? AND id = ?",
                                   arguments: [id, threadId])
                }
            }
            statusHandler?(nil)
        }
    }

    // MARK: - Draft repair

    private var draftsRepaired: Set<String> = []

    /// Once per launch, re-fetch every thread that holds a local draft.
    /// Gmail's history feed doesn't reliably report draft deletions, so a
    /// draft that was sent or discarded elsewhere can linger locally; the
    /// prune in `store` clears it as soon as we see the server's version.
    private func refreshDraftThreadsOnce(accountId: String) async {
        guard !draftsRepaired.contains(accountId) else { return }
        draftsRepaired.insert(accountId)
        let threadIds = (try? await db.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT threadId FROM message
                WHERE accountId = ? AND isDraft = 1 LIMIT 50
                """, arguments: [accountId])
        }) ?? []
        guard !threadIds.isEmpty else { return }
        let client = GmailClient(accountId: accountId, tokens: tokens)
        for threadId in threadIds {
            do {
                let g = try await client.getThread(threadId)
                try? await store(gThread: g, accountId: accountId)
            } catch MailError.http(404, _) {
                try? await deleteLocalThread(accountId: accountId, threadId: threadId)
            } catch {
                continue
            }
        }
    }

    // MARK: - "Open" label (awaiting reply / act later)

    private var openLabelIds: [String: String] = [:]

    /// The account's Gmail "Open" label id, from cache or the account row.
    public func openLabel(accountId: String) async -> String? {
        if let cached = openLabelIds[accountId] { return cached }
        let id = (try? await db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT openLabelId FROM account WHERE id = ?",
                                arguments: [accountId])
        }) ?? nil
        if let id { openLabelIds[accountId] = id }
        return id
    }

    /// Finds or creates the "Open" label in Gmail once per account, then
    /// flags any already-synced threads that carry it.
    private func ensureOpenLabel(account: inout Account) async throws {
        if let id = account.openLabelId {
            openLabelIds[account.id] = id
            return
        }
        let client = GmailClient(accountId: account.id, tokens: tokens)
        let labels = try await client.listLabels()
        let id: String
        if let existing = labels.first(where: { $0.name.caseInsensitiveCompare("Open") == .orderedSame }) {
            id = existing.id
        } else {
            id = try await client.createLabel(name: "Open").id
        }
        try await db.writer.write { [accountId = account.id] db in
            try db.execute(sql: "UPDATE account SET openLabelId = ? WHERE id = ?",
                           arguments: [id, accountId])
            try db.execute(sql: """
                UPDATE thread SET isOpen = 1 WHERE accountId = ? AND EXISTS (
                    SELECT 1 FROM thread_label tl
                    WHERE tl.accountId = thread.accountId AND tl.threadId = thread.id AND tl.labelId = ?
                )
                """, arguments: [accountId, id])
        }
        account.openLabelId = id
        openLabelIds[account.id] = id
    }

    /// Adds/removes the "Open" label on a thread.
    public func setOpen(accountId: String, threadId: String, open: Bool) async {
        guard let label = await openLabel(accountId: accountId) else { return }
        await modifyThread(accountId: accountId, threadId: threadId,
                           add: open ? [label] : [], remove: open ? [] : [label])
    }

    // MARK: - Backfill (full history, resumable)

    /// Threads pulled per sync pass. Backfill walks the ENTIRE mailbox,
    /// newest first, one chunk per pass so incremental sync stays fresh in
    /// between; the page token persists so it resumes across app launches.
    static let backfillChunk = 300

    private func continueBackfill(account: Account) async throws {
        let client = GmailClient(accountId: account.id, tokens: tokens)
        var pageToken = account.backfillPageToken
        var processed = 0

        while true {
            let page: GThreadList
            do {
                page = try await client.listThreads(pageToken: pageToken)
            } catch MailError.http(400, _) where pageToken != nil {
                // Stored page token expired — restart from the newest page;
                // already-synced threads simply re-upsert on the way down.
                pageToken = nil
                try await db.writer.write { [id = account.id] db in
                    try db.execute(sql: "UPDATE account SET backfillPageToken = NULL WHERE id = ?",
                                   arguments: [id])
                }
                continue
            }
            let stubs = page.threads ?? []

            try await withThrowingTaskGroup(of: GThread?.self) { group in
                var iterator = stubs.makeIterator()
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
                    addNext(&group)
                }
            }
            processed += stubs.count

            pageToken = page.nextPageToken
            try await db.writer.write { [id = account.id, pageToken] db in
                try db.execute(sql: "UPDATE account SET backfillPageToken = ?, lastSyncAt = ? WHERE id = ?",
                               arguments: [pageToken, Date(), id])
            }

            if pageToken == nil {
                try await db.writer.write { [id = account.id] db in
                    try db.execute(sql: "UPDATE account SET backfillDone = 1 WHERE id = ?",
                                   arguments: [id])
                }
                statusHandler?("Synced full history for \(account.email)")
                return
            }
            let total = (try? await db.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE accountId = ?",
                                 arguments: [account.id]) ?? 0
            }) ?? 0
            statusHandler?("Syncing older mail (\(account.email))… \(total) threads")
            if processed >= Self.backfillChunk { return }
        }
    }

    // MARK: - Incremental

    private func incrementalSync(account: Account) async throws {
        guard let startId = account.historyId else { return }  // baseline set by syncAll
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
            // History expired — reset; the next sync pass re-baselines and
            // walks the whole mailbox again via continueBackfill.
            try await db.writer.write { [id = account.id] db in
                try db.execute(sql: """
                    UPDATE account SET backfillDone = 0, historyId = NULL, backfillPageToken = NULL
                    WHERE id = ?
                    """, arguments: [id])
            }
            return
        }

        var arrived: [NewMail] = []
        for threadId in threadIds {
            do {
                let gThread = try await client.getThread(threadId)
                arrived += try await store(gThread: gThread, accountId: account.id, detectNewMail: true)
            } catch MailError.http(404, _) {
                try await deleteLocalThread(accountId: account.id, threadId: threadId)
            }
        }
        if !arrived.isEmpty { newMailHandler?(arrived) }

        if let newHistoryId {
            try await db.writer.write { [id = account.id] db in
                try db.execute(sql: "UPDATE account SET historyId = ?, lastSyncAt = ? WHERE id = ?",
                               arguments: [newHistoryId, Date(), id])
            }
        }
    }

    // MARK: - Storage

    /// "?, ?, ?" for an IN clause; a lone "NULL" keeps `NOT IN ()` valid
    /// (and matching nothing) when the list is empty.
    private static func questionMarks(count: Int) -> String {
        count == 0 ? "NULL" : Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// `detectNewMail` is only ever true for the incremental pass — backfill
    /// runs through here too, and would announce years of old mail.
    @discardableResult
    func store(gThread: GThread, accountId: String, detectNewMail: Bool = false) async throws -> [NewMail] {
        guard let gMessages = gThread.messages, !gMessages.isEmpty else { return [] }

        // What we already had, read before the upsert erases the answer: the
        // stored fingerprint, and (for new-mail detection) the message ids.
        let prior = try await db.writer.read { [accountId, tid = gThread.id, detectNewMail] db
            -> (sig: String?, ids: Set<String>) in
            let sig = try String.fetchOne(
                db, sql: "SELECT syncSig FROM thread WHERE accountId = ? AND id = ?",
                arguments: [accountId, tid])
            let ids = detectNewMail
                ? Set(try String.fetchAll(
                    db, sql: "SELECT id FROM message WHERE accountId = ? AND threadId = ?",
                    arguments: [accountId, tid]))
                : []
            return (sig, ids)
        }
        let priorIds = prior.ids

        var labelSet = Set<String>()
        var messages: [Message] = []
        var attachments: [Attachment] = []
        for g in gMessages {
            let (m, labels, atts) = MimeParser.localMessage(from: g, accountId: accountId)
            messages.append(m)
            labelSet.formUnion(labels)
            attachments.append(contentsOf: atts)
        }
        messages.sort { $0.date < $1.date }

        var participants: [String] = []
        for m in messages where !participants.contains(m.fromName) {
            participants.append(m.fromName)
        }

        let subject = MimeParser.decodeEntities(MimeParser.subject(of: gMessages[0]))
        let openId = await openLabel(accountId: accountId)
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
            category: ThreadCategory.derive(from: labelSet),
            hasDraft: labelSet.contains(GmailLabels.draft),
            hasAttachments: !attachments.isEmpty,
            isOpen: openId.map { labelSet.contains($0) } ?? false,
            lastSenderEmail: messages.last?.fromEmail ?? ""
        )

        // Backfill re-walks threads it already has, and the history feed
        // re-reports a thread for changes we made ourselves. Re-storing an
        // unchanged thread rewrites every body and re-indexes every message
        // for nothing, so fingerprint it and skip. Drafts are exempt: their
        // content changes underneath a stable id.
        let signature = Self.signature(thread: thread, messages: messages,
                                       labels: labelSet, attachmentCount: attachments.count)
        if !messages.contains(where: \.isDraft), prior.sig == signature { return [] }

        // Stripping HTML down to searchable text is the one genuinely
        // expensive bit of CPU here — do it before taking the write lock,
        // not while every other writer waits behind us.
        let searchBodies: [String: String] = Dictionary(
            uniqueKeysWithValues: messages.map { m in
                var body = m.bodyText ?? MimeParser.stripHTML(m.bodyHTML ?? "")
                if body.count > 100_000 { body = String(body.prefix(100_000)) }
                return (m.id, body)
            })

        // Drop local messages the server no longer has (a sent draft is
        // deleted from its thread) — upserting alone would strand them,
        // leaving a phantom message still flagged as a draft.
        let liveIds: [String] = messages.map(\.id)
        let placeholders = Self.questionMarks(count: liveIds.count)

        try await db.writer.write { [labelSet, messages, attachments, liveIds, placeholders] db in
            try thread.save(db)
            try db.execute(sql: "UPDATE thread SET syncSig = ? WHERE accountId = ? AND id = ?",
                           arguments: [signature, accountId, gThread.id])
            // Attachments first: this scopes by joining `message`, so it has
            // to run while the stale message rows are still present.
            try db.execute(
                sql: """
                DELETE FROM attachment WHERE accountId = ?
                  AND messageId NOT IN (\(placeholders))
                  AND messageId IN (
                      SELECT id FROM message WHERE accountId = ? AND threadId = ?
                  )
                """,
                arguments: StatementArguments([accountId] + liveIds + [accountId, gThread.id]))
            // Also before the message rows go: the index is keyed by their
            // rowids, so this reads them back through `message`.
            try db.execute(
                sql: """
                DELETE FROM message_fts WHERE rowid IN (
                    SELECT rowid FROM message
                    WHERE accountId = ? AND threadId = ? AND id NOT IN (\(placeholders))
                )
                """,
                arguments: StatementArguments([accountId, gThread.id] + liveIds))
            try db.execute(
                sql: """
                DELETE FROM message WHERE accountId = ? AND threadId = ?
                  AND id NOT IN (\(placeholders))
                """,
                arguments: StatementArguments([accountId, gThread.id] + liveIds))
            try db.execute(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ?",
                           arguments: [accountId, gThread.id])
            for label in labelSet {
                try ThreadLabel(accountId: accountId, threadId: gThread.id, labelId: label).save(db)
            }
            for m in messages {
                try m.save(db)
                try db.execute(sql: "DELETE FROM attachment WHERE accountId = ? AND messageId = ?",
                               arguments: [accountId, m.id])
                // `save` updates in place when the row exists, so the rowid
                // is stable and the FTS row stays keyed to this message.
                let rowid = try Int64.fetchOne(
                    db, sql: "SELECT rowid FROM message WHERE accountId = ? AND id = ?",
                    arguments: [accountId, m.id]) ?? 0
                try Self.indexFTS(db: db, rowid: rowid, message: m,
                                  subject: thread.subject, body: searchBodies[m.id] ?? "")
                try Self.rememberContact(db: db, message: m)
            }
            for a in attachments {
                try a.save(db)
            }
        }

        // Blocked sender/domain → auto-archive on arrival
        if labelSet.contains(GmailLabels.inbox) {
            let senders = messages.map(\.fromEmail)
            if try await matchesBlockRule(senders: senders) {
                await archive(accountId: accountId, threadId: gThread.id)
                return []   // blocked mail is filed away, not announced
            }
        }

        guard detectNewMail, labelSet.contains(GmailLabels.inbox) else { return [] }
        let own = try await ownEmails()

        // "Open" means awaiting a reply, so the reply ends the wait: drop the
        // label and let the thread back into the inbox views. Only a genuinely
        // new unread message counts — our own sent reply arrives read, and a
        // thread we're seeing for the first time never "became" anything.
        if thread.isOpen, !priorIds.isEmpty,
           messages.contains(where: { !priorIds.contains($0.id) && $0.isUnread && !$0.isDraft
                                      && !own.contains($0.fromEmail.lowercased()) }) {
            await setOpen(accountId: accountId, threadId: gThread.id, open: false)
        }

        return messages
            .filter { !priorIds.contains($0.id) && $0.isUnread && !$0.isDraft
                      && !own.contains($0.fromEmail.lowercased()) }
            .map { m in
                NewMail(accountId: accountId, threadId: gThread.id, messageId: m.id,
                        fromName: m.fromName.isEmpty ? m.fromEmail : m.fromName,
                        fromEmail: m.fromEmail, subject: thread.subject, snippet: m.snippet)
            }
    }

    /// Read fresh each time — cheap, and a cached copy goes stale the moment
    /// an account is added, which would announce your own sent mail.
    private func ownEmails() async throws -> Set<String> {
        Set(try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT email FROM account")
        }.map { $0.lowercased() })
    }

    // MARK: - Block rules

    private var blockRulesCache: [BlockRule]?

    private func blockRules() async throws -> [BlockRule] {
        if let cached = blockRulesCache { return cached }
        let rules = try await db.writer.read { db in
            try BlockRule.fetchAll(db)
        }
        blockRulesCache = rules
        return rules
    }

    private func matchesBlockRule(senders: [String]) async throws -> Bool {
        let rules = try await blockRules()
        guard !rules.isEmpty else { return false }
        return senders.contains { s in rules.contains { $0.matches(email: s) } }
    }

    /// Adds a block rule and archives every inbox thread that matches it.
    /// Returns the rule as stored (with its row id) plus every thread this
    /// swept out of the inbox, so the caller can put both back on undo.
    @discardableResult
    public func addBlock(pattern: String, kind: String) async throws -> (rule: BlockRule, archived: [ThreadRef]) {
        var rule = BlockRule(pattern: pattern.lowercased(), kind: kind)
        _ = try? await db.writer.write { [rule] db in
            var r = rule
            try r.save(db)
            return r
        }
        // Re-read so the caller gets the row id `didInsert` assigned.
        if let stored = try? await db.writer.read { [pattern = rule.pattern] db in
            try BlockRule.filter(Column("pattern") == pattern).fetchOne(db)
        } ?? nil {
            rule = stored
        }
        blockRulesCache = nil

        let rows: [(String, String)] = try await db.writer.read { db in
            let sql = """
                SELECT DISTINCT t.accountId, t.id FROM thread t
                JOIN thread_label tl ON tl.accountId = t.accountId AND tl.threadId = t.id AND tl.labelId = ?
                JOIN message m ON m.accountId = t.accountId AND m.threadId = t.id
                WHERE (? = 'email' AND lower(m.fromEmail) = ?)
                   OR (? = 'domain' AND lower(m.fromEmail) LIKE '%@' || ?)
                """
            return try Row.fetchAll(db, sql: sql, arguments: [
                GmailLabels.inbox, kind, rule.pattern, kind, rule.pattern,
            ]).map { ($0[0], $0[1]) }
        }
        for (accountId, threadId) in rows {
            await archive(accountId: accountId, threadId: threadId)
        }
        return (rule, rows.map { ThreadRef(accountId: $0.0, threadId: $0.1) })
    }

    public func removeBlock(_ rule: BlockRule) async {
        _ = try? await db.writer.write { db in try rule.delete(db) }
        blockRulesCache = nil
    }

    public func allBlocks() async -> [BlockRule] {
        (try? await blockRules()) ?? []
    }

    /// Indexes one message for search. `rowid` is the message row's own
    /// rowid — the index carries no copy of the columns, and search joins
    /// back through it to find the thread.
    static func indexFTS(db: Database, rowid: Int64, message m: Message,
                         subject: String, body: String) throws {
        try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [rowid])
        try db.execute(
            sql: """
            INSERT INTO message_fts (rowid, subject, sender, recipients, body)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [rowid, subject, m.fromName + " " + m.fromEmail,
                        m.toList + " " + m.ccList, body])
    }

    /// Keeps the recipient-autocomplete table current, newest sighting wins.
    static func rememberContact(db: Database, message m: Message) throws {
        guard !m.fromEmail.isEmpty else { return }
        try db.execute(
            sql: """
            INSERT INTO contact (email, name, lastSeen) VALUES (?, ?, ?)
            ON CONFLICT(email) DO UPDATE SET name = excluded.name, lastSeen = excluded.lastSeen
            WHERE excluded.lastSeen > contact.lastSeen
            """,
            arguments: [m.fromEmail.lowercased(), m.fromName, m.date])
    }

    /// Fingerprints everything `store` would write, so an unchanged thread
    /// can be skipped. Deliberately hand-rolled: Swift's own hashing is
    /// seeded per process, and a signature has to survive a relaunch.
    private static func signature(thread t: MailThread, messages: [Message],
                                  labels: Set<String>, attachmentCount: Int) -> String {
        var s = "\(t.subject)|\(t.snippet)|\(t.lastDate.timeIntervalSince1970)|"
        s += "\(t.messageCount)|\(attachmentCount)|"
        s += labels.sorted().joined(separator: ",")
        for m in messages {
            s += "|\(m.id):\(m.isUnread ? 1 : 0):\(m.isDraft ? 1 : 0)"
        }
        var hash: UInt64 = 0xcbf29ce484222325           // FNV-1a
        for byte in s.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Fetches specific threads (e.g. server search results) into the local cache.
    public func fetchAndStoreThreads(accountId: String, threadIds: [String]) async {
        let client = GmailClient(accountId: accountId, tokens: tokens)
        for id in threadIds {
            if let g = try? await client.getThread(id) {
                try? await store(gThread: g, accountId: accountId)
            }
        }
    }

    func deleteLocalThread(accountId: String, threadId: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM thread WHERE accountId = ? AND id = ?",
                           arguments: [accountId, threadId])
            try db.execute(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ?",
                           arguments: [accountId, threadId])
            // Index first — it's keyed by the message rowids.
            try db.execute(sql: """
                DELETE FROM message_fts WHERE rowid IN (
                    SELECT rowid FROM message WHERE accountId = ? AND threadId = ?
                )
                """, arguments: [accountId, threadId])
            try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND threadId = ?",
                           arguments: [accountId, threadId])
        }
    }

    // MARK: - Optimistic mutations

    /// Applies a label change locally right away, queues it, and replays.
    public func modifyThread(accountId: String, threadId: String,
                             add: [String], remove: [String]) async {
        let openId = await openLabel(accountId: accountId)
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
                sql: "UPDATE thread SET isUnread = ?, isStarred = ?, category = ?, isOpen = ? WHERE accountId = ? AND id = ?",
                arguments: [labels.contains(GmailLabels.unread),
                            labels.contains(GmailLabels.starred),
                            ThreadCategory.derive(from: labels),
                            openId.map { labels.contains($0) } ?? false,
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
        // Archiving also resolves the thread: drop the "Open" label with it.
        var remove = [GmailLabels.inbox]
        if let openId = await openLabel(accountId: accountId) { remove.append(openId) }
        await modifyThread(accountId: accountId, threadId: threadId,
                           add: [], remove: remove)
    }

    /// Reverse of `archive`. `restoreOpen` puts the "Open" label back for a
    /// thread that was sitting in Open when it got archived.
    public func unarchive(accountId: String, threadId: String, restoreOpen: Bool) async {
        var add = [GmailLabels.inbox]
        if restoreOpen, let openId = await openLabel(accountId: accountId) { add.append(openId) }
        await modifyThread(accountId: accountId, threadId: threadId, add: add, remove: [])
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
