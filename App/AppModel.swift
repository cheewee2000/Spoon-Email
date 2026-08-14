import Foundation
import SwiftUI
import GRDB
import MailCore
#if os(macOS)
import AppKit
#endif

/// Where an in-flight unsubscribe currently stands.
enum UnsubscribeStage: Equatable {
    case confirm
    case working
    case browserPending(URL)   // web form opened; user confirms when done
    case done(String)
    case failed(String)
}

struct UnsubscribeSession: Identifiable {
    let id = UUID()
    var thread: MailThread
    var sender: String
    var links: Unsubscriber.Links
    var stage: UnsubscribeStage

    /// Human-readable description of how we'll unsubscribe.
    var method: String {
        if links.https != nil {
            return links.oneClick
                ? "One-click unsubscribe (RFC 8058) — sent directly to the sender's server."
                : "Opens the sender's unsubscribe page in your browser."
        }
        return "Sends an unsubscribe email to the sender's list address."
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// One instance per process. The iOS background-refresh handler runs in
    /// launches where no window ever appears, and it needs the same database,
    /// sync engine and notifier the UI would have used.
    static let shared = AppModel()

    let db: AppDatabase
    let accountStore: AccountStore
    let syncEngine: SyncEngine
    let outbox: OutboxManager
    let notifier = MailNotifier()

    @Published var lastError: String?
    @Published var syncStatus: String?
    @Published var draft: ComposeDraft?
    @Published var undoToast: (id: String, until: Date)?
    /// The mailbox filling the window, or `nil` for the board — the
    /// side-by-side view of every mailbox at once, which is where the app
    /// starts and where Escape always lands you.
    @Published var mailbox: MailboxFilter?
    @Published var selectedThread: MailThread?
    /// Survives the mailbox switch that a drill-in performs, so the thread you
    /// clicked on the board is still selected once its column opens full-width.
    var pendingSelection: MailThread?
    /// Account new messages are composed from. Replies ignore it — they always
    /// answer from the address the mail arrived at. `nil` means "no preference",
    /// which falls back to the first account.
    @Published var defaultComposeAccountId: String? =
        UserDefaults.standard.string(forKey: AppModel.defaultComposeKey) {
        didSet {
            UserDefaults.standard.set(defaultComposeAccountId, forKey: Self.defaultComposeKey)
        }
    }
    @Published var showPalette = false
    @Published var showBlocked = false
    /// First-run setup: collects the user's Google OAuth client ID before the
    /// sign-in flow can run.
    @Published var showClientSetup = false
    @Published var openUnreadCount = 0
    @Published var unsubscribe: UnsubscribeSession?

    private var openUnreadCancellable: AnyDatabaseCancellable?
    private var backfillTask: Task<Void, Never>?

    static let undoWindow: TimeInterval = 10
    private static let defaultComposeKey = "defaultComposeAccountId"

    init() {
        do {
            db = try AppDatabase.open()
        } catch {
            fatalError("Cannot open database: \(error)")
        }
        accountStore = AccountStore(db: db, config: GoogleOAuthConfig(clientIDProvider: { Config.googleClientID }))
        syncEngine = SyncEngine(db: db, tokens: accountStore.tokens)
        outbox = OutboxManager(db: db, tokens: accountStore.tokens)
        notifier.start()
        notifier.onOpenThread = { [weak self] accountId, threadId in
            self?.openThread(accountId: accountId, threadId: threadId)
        }
        Task {
            await syncEngine.setStatusHandler { [weak self] status in
                Task { @MainActor in self?.syncStatus = status }
            }
            await syncEngine.setNewMailHandler { [weak self] items in
                Task { @MainActor in self?.notifier.post(items) }
            }
            await outbox.setOnSent { [weak self] accountId, threadId in
                Task { @MainActor in self?.didSend(accountId: accountId, threadId: threadId) }
            }
            await pushAccountEmails()
            await outbox.start()
            syncNow()
            // Backfill deliberately does NOT start here — see
            // startBackfillIfNeeded().
        }
        startPolling()
        // Sidebar badge: unread threads waiting in Open.
        openUnreadCancellable = ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE isOpen = 1 AND isUnread = 1") ?? 0
            }
            .start(in: db.writer, scheduling: .async(onQueue: .main)) { _ in
            } onChange: { [weak self] count in
                self?.openUnreadCount = count
            }
    }

    private func pushAccountEmails() async {
        let emails = Dictionary(uniqueKeysWithValues: accountStore.accounts.map { ($0.id, $0.email) })
        await outbox.updateAccountEmails(emails)
    }

    // MARK: - Accounts

    func addAccount() {
        // No client ID yet — collect it first; the setup sheet calls back
        // into this method once one is saved.
        guard Config.isConfigured else {
            showClientSetup = true
            return
        }
        Task {
            do {
                try await accountStore.addAccount()
                await pushAccountEmails()
                syncNow()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func accountEmail(_ id: String) -> String {
        accountStore.accounts.first { $0.id == id }?.email ?? ""
    }

    func accountColor(_ id: String) -> Color {
        guard let idx = accountStore.accounts.firstIndex(where: { $0.id == id }) else { return .blue }
        if let hex = accountStore.accounts[idx].colorHex, let picked = Color(hex: hex) {
            return picked
        }
        return AccountPalette.defaultColor(index: idx)
    }

    /// `nil` hands the account back to its palette slot.
    func setAccountColor(_ account: Account, hex: String?) {
        Task { await accountStore.setColor(account, hex: hex) }
    }

    // MARK: - Search

    /// Bumped by ⌘F. A counter rather than a flag so pressing it again while
    /// the field already has focus still re-focuses it.
    @Published var focusSearchRequest = 0

    /// The board has no search field of its own, so ⌘F there opens Unified —
    /// the search is across all mail anyway — and focuses that.
    func focusSearch() {
        if mailbox == nil { mailbox = .unified }
        focusSearchRequest += 1
    }

    // MARK: - Sync

    /// New mail every 20s for as long as the process lives. Owned here, not by
    /// a view: on the Mac the app keeps running after the last window closes,
    /// and a view-owned timer would stop polling (and notifying) with it. On
    /// iOS the loop simply pauses while the process is suspended.
    private var pollTask: Task<Void, Never>?
    private var pollActivity: NSObjectProtocol?

    private func startPolling() {
        #if os(macOS)
        // Without this, App Nap throttles the sleep below once every window is
        // closed — which is exactly when the poll is the only source of mail.
        pollActivity = ProcessInfo.processInfo.beginActivity(
            options: .background, reason: "Polling for new mail")
        #endif
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.syncNow()
            }
        }
    }

    /// New mail: history feed for every account. Fast, and safe to spam.
    func syncNow() { _ = syncPass() }

    /// The pass currently in flight. A second caller joins it rather than
    /// starting its own, which would bounce straight off the engine's
    /// per-account guard and return instantly — fine for the 20s timer,
    /// wrong for the background refresh, which has to *wait* for the fetch.
    private var syncTask: Task<Void, Never>?

    @discardableResult
    private func syncPass() -> Task<Void, Never>? {
        if let syncTask { return syncTask }
        let accounts = accountStore.accounts
        guard !accounts.isEmpty else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.syncEngine.syncAll(accounts: accounts)
            self.syncTask = nil
        }
        syncTask = task
        return task
    }

    /// One incremental pass, awaited to completion. No backfill — this is for
    /// the callers that have to know when new mail has actually landed: the
    /// iOS background-refresh window (which reports back to the scheduler) and
    /// pull-to-refresh (which spins until this returns).
    func syncAndWait() async {
        await syncPass()?.value
        // The engine hands new mail to the notifier through a main-actor hop;
        // give that hop a chance to run before the process is suspended.
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    /// Old mail fills in on its own slow loop so it never delays new mail.
    /// Started from the UI rather than `init`, so a background-refresh launch
    /// — which never shows a window — spends its whole budget on new mail.
    func startBackfillIfNeeded() {
        guard backfillTask == nil else { return }
        backfillTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let accounts = self.accountStore.accounts
                if !accounts.isEmpty {
                    // Repair first: it's a bounded, finite job fixing mail you
                    // already have, and behind a 300-thread backfill chunk it
                    // would crawl. It stops asking for work once it's done.
                    await self.syncEngine.repairInlineImagesPass(accounts: accounts)
                    await self.syncEngine.backfillPass(accounts: accounts)
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    // MARK: - Undo

    /// One reversible triage action. `perform` restores the state captured
    /// when the action ran, so undoing an archive of an Open thread puts it
    /// back in Open rather than the inbox.
    struct UndoableAction {
        let name: String
        let perform: () -> Void
    }

    @Published private var undoStack: [UndoableAction] = []

    private static let undoDepth = 20

    var canUndo: Bool { undoToast != nil || !undoStack.isEmpty }

    /// "Undo Archive" / "Undo Send" — drives the menu item's title.
    var undoTitle: String {
        if undoToast != nil { return "Undo Send" }
        guard let last = undoStack.last else { return "Undo" }
        return "Undo \(last.name)"
    }

    private func pushUndo(_ name: String, _ perform: @escaping () -> Void) {
        undoStack.append(UndoableAction(name: name, perform: perform))
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
    }

    /// A pending send is always the most recent thing you did, so it wins.
    func undo() {
        if undoToast != nil { undoSend(); return }
        guard let action = undoStack.popLast() else { return }
        action.perform()
    }

    // MARK: - Thread actions

    func archive(_ thread: MailThread) {
        pushUndo("Archive") { [weak self] in
            guard let self else { return }
            Task {
                await self.syncEngine.unarchive(accountId: thread.accountId, threadId: thread.id,
                                                restoreOpen: thread.isOpen)
            }
        }
        Task { await syncEngine.archive(accountId: thread.accountId, threadId: thread.id) }
    }

    /// `recordUndo: false` for the automatic mark-read when a thread is
    /// opened — that isn't a decision you made, and letting it onto the stack
    /// would bury the archive you actually want ⌘Z to reverse.
    func markRead(_ thread: MailThread, read: Bool, recordUndo: Bool = true) {
        let wasUnread = thread.isUnread
        if recordUndo {
            pushUndo(read ? "Mark Read" : "Mark Unread") { [weak self] in
                guard let self else { return }
                Task {
                    await self.syncEngine.markRead(accountId: thread.accountId, threadId: thread.id,
                                                   read: !wasUnread)
                }
            }
        }
        Task { await syncEngine.markRead(accountId: thread.accountId, threadId: thread.id, read: read) }
    }

    func toggleStar(_ thread: MailThread) {
        let wasStarred = thread.isStarred
        pushUndo(wasStarred ? "Unstar" : "Star") { [weak self] in
            guard let self else { return }
            Task {
                await self.syncEngine.toggleStar(accountId: thread.accountId, threadId: thread.id,
                                                 starred: wasStarred)
            }
        }
        Task { await syncEngine.toggleStar(accountId: thread.accountId, threadId: thread.id, starred: !wasStarred) }
    }

    /// "Open" = awaiting a reply / act on later. Lives in the Open mailbox
    /// instead of the inbox views until archived or toggled back.
    func toggleOpen(_ thread: MailThread) {
        let wasOpen = thread.isOpen
        pushUndo(wasOpen ? "Close" : "Open") { [weak self] in
            guard let self else { return }
            Task {
                await self.syncEngine.setOpen(accountId: thread.accountId, threadId: thread.id,
                                              open: wasOpen)
            }
        }
        Task { await syncEngine.setOpen(accountId: thread.accountId, threadId: thread.id, open: !wasOpen) }
    }

    // MARK: - Keyboard navigation

    func selectNext(in threads: [MailThread]) {
        guard !threads.isEmpty else { return }
        guard let sel = selectedThread,
              let idx = threads.firstIndex(where: { $0.key == sel.key }) else {
            selectedThread = threads.first
            return
        }
        if idx + 1 < threads.count { selectedThread = threads[idx + 1] }
    }

    func selectPrevious(in threads: [MailThread]) {
        guard !threads.isEmpty else { return }
        guard let sel = selectedThread,
              let idx = threads.firstIndex(where: { $0.key == sel.key }) else {
            selectedThread = threads.first
            return
        }
        if idx > 0 { selectedThread = threads[idx - 1] }
    }

    /// Archive the selection and advance to the next thread (Superhuman "e").
    func archiveSelected(in threads: [MailThread]) {
        guard let sel = selectedThread else { return }
        let idx = threads.firstIndex { $0.key == sel.key }
        archive(sel)
        if let idx {
            if idx + 1 < threads.count {
                selectedThread = threads[idx + 1]
            } else if idx > 0 {
                selectedThread = threads[idx - 1]
            } else {
                selectedThread = nil
            }
        }
    }

    // MARK: - Compose

    /// The account a brand-new message is sent from: the one pinned as default,
    /// falling back to the first when nothing is pinned (or the pinned account
    /// has since been removed).
    var defaultComposeAccount: Account? {
        accountStore.accounts.first { $0.id == defaultComposeAccountId }
            ?? accountStore.accounts.first
    }

    /// Pins — or, when passed the account already pinned, unpins — the address
    /// new messages default to.
    func setDefaultComposeAccount(_ accountId: String) {
        defaultComposeAccountId = defaultComposeAccountId == accountId ? nil : accountId
    }

    func compose() {
        guard let account = defaultComposeAccount else {
            lastError = "Add an account first."
            return
        }
        draft = ComposeDraft(accountId: account.id)
    }

    /// A mailto: link inside a message opens our own composer, not whatever
    /// the system has registered for mail. It's a new message rather than a
    /// reply, so it leaves from the default address like any other.
    func compose(to address: String) {
        guard let account = defaultComposeAccount else {
            lastError = "Add an account first."
            return
        }
        draft = ComposeDraft(accountId: account.id, to: address)
    }

    func reply(to thread: MailThread, all: Bool) {
        Task {
            guard let last = lastMessage(in: thread) else { return }
            let myEmail = accountEmail(thread.accountId).lowercased()
            // Replying to your own message answers the people you sent it to;
            // otherwise it answers the sender.
            let answering: [String] = last.fromEmail.lowercased() == myEmail
                ? AddressList.split(last.toList)
                : [last.fromName == last.fromEmail
                    ? last.fromEmail
                    : "\(last.fromName) <\(last.fromEmail)>"]
            let others = all
                ? AddressList.split(last.toList) + AddressList.split(last.ccList)
                : []
            let recipients = AddressList.replyRecipients(
                to: answering, others: others, me: myEmail)
            let to = recipients.to.joined(separator: ", ")
            let cc = recipients.cc.joined(separator: ", ")
            let subject = thread.subject.hasPrefix("Re:") ? thread.subject : "Re: \(thread.subject)"
            let references = (last.referencesHeader + " " + last.messageIdHeader)
                .trimmingCharacters(in: .whitespaces)
            draft = ComposeDraft(
                accountId: thread.accountId, to: to, cc: cc, subject: subject,
                body: "",
                quotedText: quote(last), quotedHTML: replyQuoteHTML(last),
                threadId: thread.id, inReplyTo: last.messageIdHeader, references: references)
        }
    }

    func forward(_ thread: MailThread) {
        guard let last = lastMessage(in: thread) else { return }
        let subject = thread.subject.hasPrefix("Fwd:") ? thread.subject : "Fwd: \(thread.subject)"
        let header = """
        ---------- Forwarded message ----------
        From: \(last.fromName) <\(last.fromEmail)>
        Date: \(last.date.formatted(date: .abbreviated, time: .shortened))
        Subject: \(thread.subject)
        To: \(last.toList)
        """
        let text = last.bodyText ?? MimeParser.stripHTML(last.bodyHTML ?? "")
        var quotedHTML: String?
        if let html = last.bodyHTML, !html.isEmpty {
            quotedHTML = "<div style=\"color:#555;font-size:12px;margin-top:12px\">"
                + ThreadHTML.escape(header).replacingOccurrences(of: "\n", with: "<br>")
                + "</div><br>" + html
        }
        draft = ComposeDraft(accountId: thread.accountId, subject: subject,
                             body: "",
                             quotedText: header + "\n\n" + text,
                             quotedHTML: quotedHTML)
    }

    /// Opens the compose sheet pre-filled from an existing Gmail draft.
    /// Sending replaces the draft (it's deleted after successful delivery).
    /// Rebuilds the compose payload for a stored draft — shared by "edit
    /// draft" and by the snapshot that "delete draft" needs to be undoable.
    private func composeDraft(messageId: String, in thread: MailThread) -> ComposeDraft? {
        let message: Message? = try? db.writer.read { db in
            try Message.fetchOne(
                db,
                sql: "SELECT * FROM message WHERE accountId = ? AND id = ?",
                arguments: [thread.accountId, messageId])
        }
        guard let m = message, m.isDraft else { return nil }
        // A reply draft carries References; a standalone draft doesn't.
        let isReply = !m.referencesHeader.isEmpty
        let inReplyTo = m.referencesHeader
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .last ?? ""
        return ComposeDraft(
            accountId: thread.accountId,
            to: m.toList, cc: m.ccList,
            subject: thread.subject,
            body: m.bodyText ?? MimeParser.stripHTML(m.bodyHTML ?? ""),
            bodyHTML: m.bodyHTML ?? "",
            threadId: isReply ? m.threadId : nil,
            inReplyTo: isReply ? inReplyTo : "",
            references: isReply ? m.referencesHeader : "",
            draftMessageId: m.id)
    }

    func editDraft(messageId: String, in thread: MailThread) {
        guard var d = composeDraft(messageId: messageId, in: thread) else { return }
        guard d.bodyHTML.contains("cid:") else {
            draft = d
            return
        }
        // The body cites images by content id; without their bytes the editor
        // would drop them, and re-saving would send a draft with holes in it.
        Task {
            d.attachments = await inlineImages(messageId: messageId,
                                               accountId: thread.accountId,
                                               html: d.bodyHTML)
            draft = d
        }
    }

    /// Downloads the parts a draft's HTML references as `cid:`, keyed back to
    /// the same content ids so a re-save reuses them.
    private func inlineImages(messageId: String, accountId: String,
                              html: String) async -> [ComposeAttachment] {
        let parts: [Attachment] = (try? await db.writer.read { db in
            try Attachment.fetchAll(
                db,
                sql: """
                    SELECT * FROM attachment
                    WHERE accountId = ? AND messageId = ? AND contentId <> ''
                    """,
                arguments: [accountId, messageId])
        }) ?? []
        let cited = parts.filter { html.contains("cid:\($0.contentId)") }
        guard !cited.isEmpty else { return [] }

        let client = accountStore.client(for: accountId)
        var out: [ComposeAttachment] = []
        for part in cited {
            guard let data = try? await client.downloadAttachment(messageId: messageId,
                                                                  partId: part.partId) else { continue }
            out.append(ComposeAttachment(id: part.contentId,
                                         filename: part.filename,
                                         mimeType: part.mimeType,
                                         data: data))
        }
        if out.count < cited.count {
            // Better to say so than to let a re-save quietly send a draft with
            // its images missing.
            lastError = "\(cited.count - out.count) inline image(s) couldn't be loaded — "
                + "they'll be dropped if you save or send this draft."
        }
        return out
    }

    /// Saves the compose sheet's content to Gmail as a draft. Editing an
    /// existing draft updates it in place; otherwise a new draft is created.
    func saveDraft(_ d: ComposeDraft) {
        Task {
            do {
                let raw = MimeBuilder.build(
                    fromEmail: accountEmail(d.accountId),
                    to: d.to, cc: d.cc, bcc: d.bcc,
                    subject: d.subject, bodyText: d.body, bodyHTML: d.bodyHTML,
                    quotedText: d.quotedText, quotedHTML: d.quotedHTML,
                    attachments: d.attachments,
                    inReplyTo: d.inReplyTo, references: d.references)
                let client = accountStore.client(for: d.accountId)
                var updated = false
                if !d.draftMessageId.isEmpty {
                    updated = try await client.updateDraft(
                        messageId: d.draftMessageId, raw: raw, threadId: d.threadId)
                }
                if !updated {
                    try await client.createDraft(raw: raw, threadId: d.threadId)
                }
                flash("Draft saved")
                syncNow()
            } catch {
                lastError = "Save draft failed: \(error.localizedDescription)"
            }
        }
    }

    /// Deletes a Gmail draft (server first, then the local cache row).
    func deleteDraft(messageId: String, in thread: MailThread) {
        // Snapshot the content before it's gone. Undo re-creates it as a new
        // draft — the old Gmail draft id dies with the server-side delete, so
        // clear it or the restore would try to update a draft that isn't there.
        var snapshot = composeDraft(messageId: messageId, in: thread)
        snapshot?.draftMessageId = ""
        Task {
            do {
                let client = accountStore.client(for: thread.accountId)
                try await client.deleteDraft(messageId: messageId)
                try? await db.purgeDraft(accountId: thread.accountId, messageId: messageId)
                if let snapshot {
                    pushUndo("Delete Draft") { [weak self] in self?.saveDraft(snapshot) }
                }
                flash("Draft deleted")
                syncNow()
            } catch {
                lastError = "Delete draft failed: \(error.localizedDescription)"
            }
        }
    }

    /// Wraps the replied-to message's HTML in a standard attribution +
    /// blockquote so its formatting survives in the outgoing mail.
    private func replyQuoteHTML(_ m: Message) -> String? {
        guard let html = m.bodyHTML, !html.isEmpty else { return nil }
        let date = m.date.formatted(date: .abbreviated, time: .shortened)
        let attribution = ThreadHTML.escape("On \(date), \(m.fromName) <\(m.fromEmail)> wrote:")
        return "<div style=\"color:#555;font-size:12px;margin-top:12px\">\(attribution)</div>"
            + "<blockquote style=\"border-left:2px solid #ccc;margin:6px 0 0;padding-left:10px\">\(html)</blockquote>"
    }

    private func lastMessage(in thread: MailThread) -> Message? {
        try? db.writer.read { db in
            try Message.fetchOne(
                db,
                sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY date DESC LIMIT 1",
                arguments: [thread.accountId, thread.id])
        }
    }

    private func quote(_ m: Message) -> String {
        let text = m.bodyText ?? MimeParser.stripHTML(m.bodyHTML ?? "")
        let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        let date = m.date.formatted(date: .abbreviated, time: .shortened)
        return "On \(date), \(m.fromName) <\(m.fromEmail)> wrote:\n\(quoted)"
    }

    /// Async, and off the `message` table: the old LIKE-scan over every
    /// message took 144ms per keystroke on the main thread. `contact` holds
    /// one row per sender and is kept current as mail is stored.
    func suggestContacts(_ query: String) async -> [(name: String, email: String)] {
        let rows = (try? await db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT name, email FROM contact
                WHERE email LIKE ? OR name LIKE ?
                ORDER BY lastSeen DESC LIMIT 5
                """, arguments: ["%\(query)%", "%\(query)%"])
        }) ?? []
        return rows.map { ($0["name"] ?? "", $0["email"] ?? "") }
    }

    // MARK: - Send / undo send / send later

    func send(draft: ComposeDraft, at date: Date?) {
        let sendAt = date ?? Date().addingTimeInterval(Self.undoWindow)
        let item = OutboxItem(
            accountId: draft.accountId, threadId: draft.threadId,
            toList: draft.to, ccList: draft.cc, bccList: draft.bcc,
            subject: draft.subject, bodyText: draft.body, bodyHTML: draft.bodyHTML,
            quotedText: draft.quotedText, quotedHTML: draft.quotedHTML,
            attachments: draft.attachments,
            inReplyTo: draft.inReplyTo, references: draft.references,
            draftMessageId: draft.draftMessageId,
            sendAt: sendAt)
        Task {
            do {
                try await outbox.schedule(item)
                if date == nil {
                    undoToast = (item.id, sendAt)
                } else {
                    syncStatus = "Scheduled for \(sendAt.formatted(date: .abbreviated, time: .shortened))"
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if syncStatus?.hasPrefix("Scheduled") == true { syncStatus = nil }
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Unsubscribe / block / attachments

    /// Opens the unsubscribe sheet: confirm → progress → result. The thread is
    /// archived once the unsubscribe actually lands.
    func beginUnsubscribe(_ thread: MailThread) {
        guard let m = lastMessage(in: thread),
              let links = Unsubscriber.parse(header: m.listUnsubscribe,
                                             postHeader: m.listUnsubscribePost) else {
            lastError = "No unsubscribe information in this message."
            return
        }
        unsubscribe = UnsubscribeSession(thread: thread,
                                         sender: m.fromEmail.isEmpty ? thread.participants : m.fromEmail,
                                         links: links,
                                         stage: .confirm)
    }

    func confirmUnsubscribe() {
        guard let session = unsubscribe else { return }
        setUnsubscribeStage(.working, for: session.id)
        Task {
            do {
                switch try await Unsubscriber.perform(session.links) {
                case .oneClickDone:
                    await syncEngine.archive(accountId: session.thread.accountId,
                                             threadId: session.thread.id)
                    setUnsubscribeStage(.done("Unsubscribed from \(session.sender). Conversation archived."),
                                        for: session.id)
                case .openedBrowser(let url):
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    await UIApplication.shared.open(url)
                    #endif
                    setUnsubscribeStage(.browserPending(url), for: session.id)
                case .sendEmail(let to, let subject):
                    let item = OutboxItem(
                        accountId: session.thread.accountId, threadId: nil,
                        toList: to, ccList: "", bccList: "",
                        subject: subject, bodyText: "unsubscribe",
                        sendAt: Date())
                    try await outbox.schedule(item)
                    await syncEngine.archive(accountId: session.thread.accountId,
                                             threadId: session.thread.id)
                    setUnsubscribeStage(.done("Unsubscribe request emailed to \(to). Conversation archived."),
                                        for: session.id)
                }
            } catch {
                setUnsubscribeStage(.failed(error.localizedDescription), for: session.id)
            }
        }
    }

    /// The web form can't report back, so the user confirms it finished.
    func finishUnsubscribeFromBrowser() {
        guard let session = unsubscribe else { return }
        Task {
            await syncEngine.archive(accountId: session.thread.accountId,
                                     threadId: session.thread.id)
            setUnsubscribeStage(.done("Conversation archived."), for: session.id)
        }
    }

    func dismissUnsubscribe() {
        if case .done(let text)? = unsubscribe?.stage { flash(text) }
        unsubscribe = nil
    }

    private func setUnsubscribeStage(_ stage: UnsubscribeStage, for id: UUID) {
        guard var session = unsubscribe, session.id == id else { return }
        session.stage = stage
        unsubscribe = session
    }

    func block(_ thread: MailThread, wholeDomain: Bool) {
        Task {
            guard let m = lastMessage(in: thread) else { return }
            let email = m.fromEmail.lowercased()
            let pattern = wholeDomain ? String(email.split(separator: "@").last ?? "") : email
            guard !pattern.isEmpty else { return }
            do {
                let (rule, archived) = try await syncEngine.addBlock(
                    pattern: pattern, kind: wholeDomain ? "domain" : "email")
                // Undo drops the rule *and* returns everything it swept out.
                pushUndo("Block \(pattern)") { [weak self] in
                    guard let self else { return }
                    Task {
                        await self.syncEngine.removeBlock(rule)
                        for ref in archived {
                            await self.syncEngine.unarchive(accountId: ref.accountId,
                                                            threadId: ref.threadId,
                                                            restoreOpen: false)
                        }
                    }
                }
                flash("Blocked \(pattern) — matching mail auto-archives")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func loadBlockRules() async -> [BlockRule] {
        await syncEngine.allBlocks()
    }

    func unblock(_ rule: BlockRule) {
        pushUndo("Unblock \(rule.pattern)") { [weak self] in
            guard let self else { return }
            Task { try? await self.syncEngine.addBlock(pattern: rule.pattern, kind: rule.kind) }
        }
        Task { await syncEngine.removeBlock(rule) }
    }

    func download(_ attachment: Attachment) {
        Task {
            flash("Downloading \(attachment.filename)…")
            do {
                let client = accountStore.client(for: attachment.accountId)
                let data = try await client.downloadAttachment(
                    messageId: attachment.messageId, partId: attachment.partId)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                var url = downloads.appendingPathComponent(attachment.filename)
                var n = 1
                while FileManager.default.fileExists(atPath: url.path) {
                    let base = (attachment.filename as NSString).deletingPathExtension
                    let ext = (attachment.filename as NSString).pathExtension
                    url = downloads.appendingPathComponent("\(base)-\(n)\(ext.isEmpty ? "" : "." + ext)")
                    n += 1
                }
                try data.write(to: url)
                flash("Saved \(url.lastPathComponent) to Downloads")
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                #endif
            } catch {
                lastError = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// Transient status-bar message.
    private func flash(_ text: String) {
        syncStatus = text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if syncStatus == text { syncStatus = nil }
        }
    }

    /// Pulls server-side search results into the local cache; the live FTS
    /// observation then picks them up automatically.
    func serverSearch(_ query: String) {
        Task {
            syncStatus = "Searching Gmail…"
            for account in accountStore.accounts {
                let client = accountStore.client(for: account.id)
                if let ids = try? await client.searchMessageIds(q: query, maxResults: 25) {
                    let threadIds = Array(Set(ids.map(\.threadId)))
                    await syncEngine.fetchAndStoreThreads(accountId: account.id, threadIds: threadIds)
                }
            }
            syncStatus = nil
        }
    }

    /// A send just landed. Pull that one thread straight in so the message
    /// shows up in the conversation now, rather than whenever the next
    /// history sync happens to run.
    /// Clicking a new-mail banner brings the app forward on that thread.
    func openThread(accountId: String, threadId: String) {
        #if os(macOS)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        guard let thread = try? db.writer.read({ db in
            try MailThread.fetchOne(db, sql: "SELECT * FROM thread WHERE accountId = ? AND id = ?",
                                    arguments: [accountId, threadId])
        }) else { return }
        open(thread, in: mailbox ?? .unified)
    }

    // MARK: - Navigation

    /// Open one thread full-width in a given mailbox. From the board this is a
    /// drill-in: the column you clicked becomes the window, and Escape brings
    /// the board back.
    func open(_ thread: MailThread, in filter: MailboxFilter) {
        pendingSelection = thread
        mailbox = filter
        selectedThread = thread
    }

    /// Back out to the board. Deepest level first: a thread selection goes
    /// before the mailbox does, so Escape retraces the way you came in.
    func escape() {
        if selectedThread != nil {
            selectedThread = nil
        } else if mailbox != nil {
            mailbox = nil
        }
    }

    private func didSend(accountId: String, threadId: String) {
        Task {
            await syncEngine.fetchAndStoreThreads(accountId: accountId, threadIds: [threadId])
            syncNow()
        }
    }

    func undoSend() {
        guard let toast = undoToast else { return }
        undoToast = nil
        Task {
            let cancelled = await outbox.cancel(id: toast.id)
            if !cancelled {
                lastError = "Too late — the message was already sent."
            }
        }
    }
}
