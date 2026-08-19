import Foundation
import SwiftUI
import GRDB
import MailCore

/// Live thread list for one mailbox, backed by GRDB ValueObservation.
@MainActor
final class ThreadListModel: ObservableObject {
    @Published private(set) var threads: [MailThread] = []
    private var cancellable: AnyDatabaseCancellable?
    private(set) var filter: MailboxFilter = .unified

    static let pageSize = 300

    /// How many threads a page adds. The board runs nine of these lists at
    /// once, so its columns page in far smaller bites than the full-width
    /// list does.
    let pageSize: Int
    private var limit: Int
    private var searching = false

    init(pageSize: Int = ThreadListModel.pageSize) {
        self.pageSize = pageSize
        self.limit = pageSize
        Self.live.append(Weak(value: self))
    }

    // MARK: - Optimistic user actions

    /// Every list alive right now, so a triage keystroke can update all of
    /// them (the full-width list, the board's columns) without the model
    /// having to know which is on screen.
    private struct Weak { weak var value: ThreadListModel? }
    private static var live: [Weak] = []
    private static var lastUserAction: Date = .distantPast

    /// Called for a change you made by hand (archive, star, open…). For the
    /// next second, deliveries apply straight away instead of joining the
    /// coalesced sync flood — a keystroke must never wait on a batching
    /// window that exists for background writes.
    static func noteUserAction() {
        lastUserAction = Date()
        live.removeAll { $0.value == nil }
    }

    /// Drops the thread from every list currently showing it, right now,
    /// before the database write lands. Each list keeps filtering it out of
    /// deliveries until one arrives without it (the commit) — otherwise the
    /// per-thread sync commits landing in between would flash it back.
    static func hideEverywhere(_ key: String) {
        noteUserAction()
        for entry in live {
            guard let list = entry.value, list.threads.contains(where: { $0.key == key }) else { continue }
            list.hidden[key] = Date()
            list.pendingApply?.cancel()
            list.pendingApply = nil
            list.collapse(key)
        }
    }

    /// Keys whose rows are mid-collapse: still in `threads` (so the row keeps
    /// its identity and can animate its own height to zero) but drawn at
    /// zero height. Removed from the array only once invisible.
    ///
    /// macOS List doesn't animate ForEach removals — a row deleted inside
    /// withAnimation just vanishes between frames — so instead of animating
    /// the diff, we animate the row's frame and then delete it silently.
    @Published private(set) var collapsing: Set<String> = []
    static let collapseDuration: TimeInterval = 0.25
    private var deferredDelivery: [MailThread]?

    private func collapse(_ key: String) {
        withAnimation(.easeInOut(duration: Self.collapseDuration)) {
            _ = collapsing.insert(key)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.collapseDuration + 0.03) * 1_000_000_000))
            guard let self else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                self.threads.removeAll { $0.key == key }
                self.collapsing.remove(key)
            }
            if self.collapsing.isEmpty, let deferred = self.deferredDelivery {
                self.deferredDelivery = nil
                self.apply(deferred)
            }
        }
    }

    /// Key → when it was hidden. Released once a delivery arrives without
    /// it, or after a few seconds regardless (an undo that lands before the
    /// commit's delivery would otherwise keep it filtered).
    private var hidden: [String: Date] = [:]

    private func filtered(_ threads: [MailThread]) -> [MailThread] {
        guard !hidden.isEmpty else { return threads }
        let present = Set(threads.map(\.key))
        let now = Date()
        hidden = hidden.filter { present.contains($0.key) && now.timeIntervalSince($0.value) < 3 }
        guard !hidden.isEmpty else { return threads }
        return threads.filter { hidden[$0.key] == nil }
    }

    func observe(db: AppDatabase, filter: MailboxFilter) {
        self.filter = filter
        searching = false
        limit = pageSize
        startObservation(db: db)
    }

    /// Called when the bottom of the list scrolls into view: widen the
    /// window and re-observe. No-op once the mailbox is exhausted.
    func loadMore(db: AppDatabase) {
        guard !searching, threads.count >= limit else { return }
        limit += pageSize
        startObservation(db: db)
    }

    private func startObservation(db: AppDatabase) {
        cancellable?.cancel()
        pendingApply?.cancel()
        pendingApply = nil
        lastApplied = .distantPast
        let filter = self.filter
        let limit = self.limit
        let observation = ValueObservation.tracking { db in
            try filter.fetch(db, limit: limit)
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("thread observation error: \(error)")
        } onChange: { [weak self] threads in
            self?.apply(threads)
        }
    }

    // A sync pass commits one transaction per thread, and every commit
    // re-delivers this list — which makes SwiftUI re-diff hundreds of rows
    // for changes you can't see. Take the first one straight away (so the
    // list never lags a click) and coalesce the flood behind it.
    private static let coalesceWindow: TimeInterval = 0.3
    private var lastApplied: Date = .distantPast
    private var pendingApply: Task<Void, Never>?
    private var latest: [MailThread] = []

    private func apply(_ threads: [MailThread]) {
        // A delivery landing mid-collapse would yank the shrinking row out
        // (or, for a commit that hasn't landed yet, re-order under it). Hold
        // it until the collapse finishes.
        if !collapsing.isEmpty {
            deferredDelivery = threads
            return
        }
        let threads = filtered(threads)
        latest = threads
        let sinceLast = Date().timeIntervalSince(lastApplied)
        let userDriven = Date().timeIntervalSince(Self.lastUserAction) < 1
        guard sinceLast < Self.coalesceWindow, !userDriven else {
            pendingApply?.cancel()
            pendingApply = nil
            lastApplied = Date()
            self.threads = threads
            return
        }
        guard pendingApply == nil else { return }
        let wait = Self.coalesceWindow - sinceLast
        pendingApply = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingApply = nil
            self.lastApplied = Date()
            self.threads = self.latest
        }
    }

    /// Live FTS5 search across all accounts.
    func observeSearch(db: AppDatabase, query: String) {
        searching = true
        cancellable?.cancel()
        guard let match = Self.ftsQuery(query) else {
            threads = []
            return
        }
        let observation = ValueObservation.tracking { db in
            try MailSearch.threads(db, match: match)
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("search observation error: \(error)")
        } onChange: { [weak self] threads in
            guard let self else { return }
            self.threads = self.filtered(threads)
        }
    }

    static func ftsQuery(_ raw: String) -> String? { MailSearch.ftsQuery(raw) }
}

/// Live message list (plus attachment metadata) for one thread.
@MainActor
final class ThreadDetailModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var attachments: [String: [Attachment]] = [:]
    /// The rendered conversation. Built here, off the main thread, and only
    /// when the data actually changes — building it inside the view's `body`
    /// meant re-concatenating every message body (often megabytes) on every
    /// unrelated redraw, including each tick of the sync status line.
    @Published private(set) var html: String = ""
    private var cancellable: AnyDatabaseCancellable?
    /// The inline images whose bytes have come down, shared with the database
    /// queue that renders the page. Held in a box rather than a property
    /// because the render runs off the main actor.
    private let inlineImages = InlineImageMap()
    private var inlineTask: Task<Void, Never>?
    /// Sender address → `data:` URI, filled in as the lookups land. Same
    /// arrangement as the inline images: shared with the render, which runs
    /// off the main actor.
    private let avatars = AvatarMap()
    private var avatarTask: Task<Void, Never>?
    private var threadKey = ""

    func observe(db: AppDatabase, accounts: AccountStore, thread: MailThread) {
        cancellable?.cancel()
        let accountId = thread.accountId
        let threadId = thread.id
        if threadKey != thread.key {
            threadKey = thread.key
            inlineTask?.cancel()
            inlineImages.clear()
            avatarTask?.cancel()
            avatars.clear()
        }
        let client = accounts.client(for: accountId)
        let inlineImages = self.inlineImages
        let avatars = self.avatars
        let observation = ValueObservation.tracking { db -> ([Message], [String: [Attachment]], String, Int) in
            let messages = try Message.fetchAll(
                db,
                sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY date",
                arguments: [accountId, threadId])
            let attachments = try Attachment.fetchAll(
                db,
                sql: """
                SELECT a.* FROM attachment a
                JOIN message m ON m.accountId = a.accountId AND m.id = a.messageId
                WHERE m.accountId = ? AND m.threadId = ?
                """,
                arguments: [accountId, threadId])
            let byMessage = Dictionary(grouping: attachments, by: \.messageId)
            // Stamp the render with the map versions it was built from: the
            // page travels DB queue → main, and the fetch tasks can land bytes
            // and publish a fresher page in between. Without the stamp that
            // stale page overwrites the good one, and — the maps now being
            // full — nothing asks for a re-render until an unrelated write.
            let generation = inlineImages.version + avatars.version
            return (messages, byMessage,
                    ThreadHTML.render(messages: messages, attachments: byMessage,
                                      inlineImages: inlineImages.snapshot(),
                                      avatars: avatars.snapshot()),
                    generation)
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("message observation error: \(error)")
        } onChange: { [weak self] (messages, attachments, html, generation) in
            guard let self else { return }
            self.messages = messages
            self.attachments = attachments
            self.html = html
            self.fetchInlineImages(messages: messages, attachments: attachments, client: client)
            self.fetchAvatars(messages: messages, attachments: attachments)
            if generation != inlineImages.version + avatars.version {
                // Rendered from maps that have since moved on — rebuild.
                Task { [weak self] in
                    guard let self else { return }
                    self.html = await self.rerender(messages: messages, attachments: attachments)
                }
            }
        }
    }

    /// Looks up a picture for each distinct sender in the thread and re-renders
    /// once any of them land. Senders already resolved (or already known to
    /// have none) cost nothing — the store answers those from its cache.
    private func fetchAvatars(messages: [Message], attachments: [String: [Attachment]]) {
        let wanted = Set(messages.map { $0.fromEmail.lowercased() })
            .filter { !$0.isEmpty && !avatars.has($0) }
        guard !wanted.isEmpty else { return }

        let map = avatars
        avatarTask?.cancel()
        avatarTask = Task { [weak self] in
            var landed = false
            for email in wanted {
                if Task.isCancelled { return }
                guard let uri = await AvatarStore.shared.dataURI(for: email) else {
                    // Remembered as a miss so a later render doesn't re-ask.
                    map.set(email: email, uri: nil)
                    continue
                }
                map.set(email: email, uri: uri)
                landed = true
            }
            guard landed, !Task.isCancelled, let self else { return }
            self.html = await self.rerender(messages: messages, attachments: attachments)
        }
    }

    /// Rebuilding the page re-serializes every body, base64 payloads included
    /// — keep it off the main thread.
    private func rerender(messages: [Message],
                          attachments: [String: [Attachment]]) async -> String {
        let inline = inlineImages
        let avatars = self.avatars
        return await Task.detached(priority: .userInitiated) {
            ThreadHTML.render(messages: messages, attachments: attachments,
                              inlineImages: inline.snapshot(), avatars: avatars.snapshot())
        }.value
    }

    /// Pulls down the parts the bodies cite as `cid:` and re-renders once they
    /// land. A web view can't resolve `cid:` itself, so until this runs those
    /// images are holes in the message.
    private func fetchInlineImages(messages: [Message],
                                   attachments: [String: [Attachment]],
                                   client: GmailClient) {
        var wanted: [String: [Attachment]] = [:]
        for m in messages {
            let cited = ThreadHTML.citedIds(in: m.bodyHTML ?? "")
            guard !cited.isEmpty else { continue }
            let have = inlineImages.resolved(messageId: m.id)
            let parts = (attachments[m.id] ?? []).filter {
                let cid = ThreadHTML.normalizeCID($0.contentId)
                return !cid.isEmpty && cited.contains(cid) && !have.contains(cid)
            }
            if !parts.isEmpty { wanted[m.id] = parts }
        }
        guard !wanted.isEmpty else { return }

        let map = inlineImages
        inlineTask?.cancel()
        inlineTask = Task { [weak self] in
            var landed = false
            for (messageId, parts) in wanted {
                if Task.isCancelled { return }
                let bytes = await InlineImageCache.shared.data(for: parts, client: client)
                guard !bytes.isEmpty else { continue }
                for part in parts {
                    guard let data = bytes[part.partId] else { continue }
                    map.set(messageId: messageId,
                            contentId: ThreadHTML.normalizeCID(part.contentId),
                            uri: "data:\(part.mimeType);base64,\(data.base64EncodedString())")
                    landed = true
                }
            }
            guard landed, !Task.isCancelled, let self else { return }
            let html = await self.rerender(messages: messages, attachments: attachments)
            guard !Task.isCancelled else { return }
            self.html = html
        }
    }
}

/// messageId → content id → `data:` URI. Written from the fetch task, read on
/// the database queue that renders the thread, so it carries its own lock.
final class InlineImageMap: @unchecked Sendable {
    private var storage: [String: [String: String]] = [:]
    private var _version = 0
    private let lock = NSLock()

    /// Bumps on every write, so a render can tell whether it was built from
    /// the current contents.
    var version: Int {
        lock.lock(); defer { lock.unlock() }
        return _version
    }

    func snapshot() -> [String: [String: String]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func resolved(messageId: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(storage[messageId]?.keys ?? [:].keys)
    }

    func set(messageId: String, contentId: String, uri: String) {
        lock.lock(); defer { lock.unlock() }
        storage[messageId, default: [:]][contentId] = uri
        _version += 1
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage = [:]
        _version += 1
    }
}

/// Sender address → `data:` URI, with the same lock-and-snapshot arrangement.
/// A stored `nil` is a sender that hasn't got a picture, which is worth
/// remembering: it's what stops the render from asking again.
final class AvatarMap: @unchecked Sendable {
    private var storage: [String: String?] = [:]
    private var _version = 0
    private let lock = NSLock()

    var version: Int {
        lock.lock(); defer { lock.unlock() }
        return _version
    }

    func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage.compactMapValues { $0 }
    }

    func has(_ email: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage[email] != nil
    }

    func set(email: String, uri: String?) {
        lock.lock(); defer { lock.unlock() }
        storage[email] = .some(uri)
        if uri != nil { _version += 1 }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage = [:]
        _version += 1
    }
}
