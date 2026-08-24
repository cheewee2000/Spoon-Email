import Foundation
import SwiftUI
#if os(iOS)
import WidgetKit
#endif
import GRDB
import MailCore
#if os(macOS)
import AppKit
#endif

/// Where an in-flight unsubscribe currently stands.
enum UnsubscribeStage: Equatable {
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
    /// The rail's saved arrangement — which is also the board's column order
    /// and their widths. Owned here so model-level navigation and the canvas
    /// read one source.
    let order = SidebarOrder()

    @Published var lastError: String?
    @Published var syncStatus: String?
    @Published var draft: ComposeDraft?
    @Published var undoToast: (id: String, until: Date)?
    /// The mailbox filling the window, or `nil` for the board — the
    /// side-by-side view of every mailbox at once, which is where the app
    /// starts and where Escape always lands you.
    @Published var mailbox: MailboxFilter?
    @Published var selectedThread: MailThread?
    /// The row currently under the pointer, if any — triage hotkeys act on it
    /// in preference to the selection, so hover-then-keystroke works without a
    /// click (and on the board, which has no selection at all). Deliberately
    /// not @Published: no view renders from it, and hover churns too fast to
    /// be worth an objectWillChange per row crossing.
    var hoveredThread: MailThread?
    /// The list model behind the focused column, so keyboard triage and the
    /// palette act on the rows beside the reader. Weak: the column that
    /// created it owns it.
    weak var activeList: ThreadListModel?
    /// Which way the reader's last thread swap went (true = toward the next,
    /// lower row), so the incoming thread slides in from the side you moved.
    var readerSlideForward = true
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
            await syncEngine.setAuthFailureHandler { [weak self] accountId in
                Task { @MainActor in self?.accountStore.markNeedsReauth(accountId) }
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
            loadLabels()
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
        #if os(iOS)
        startWidgetSnapshots()
        #endif
    }

    #if os(iOS)
    private var widgetCancellable: AnyDatabaseCancellable?

    /// Keeps the home-screen widget's snapshot current: re-fetched whenever
    /// the threads it shows (or the two counts) change, written to the App
    /// Group container, and the widget told to redraw.
    private func startWidgetSnapshots() {
        widgetCancellable = ValueObservation
            .tracking { db -> (Int, Int, [MailThread]) in
                let unified = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM thread t
                    JOIN account a ON a.id = t.accountId AND a.includeInUnified = 1
                    JOIN thread_label tl ON tl.accountId = t.accountId AND tl.threadId = t.id AND tl.labelId = ?
                    WHERE t.isOpen = 0 AND t.isUnread = 1
                    """, arguments: [GmailLabels.inbox]) ?? 0
                let open = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE isOpen = 1 AND isUnread = 1") ?? 0
                let threads = try MailboxFilter.unified.fetch(db, limit: 8)
                return (unified, open, threads)
            }
            .removeDuplicates { $0 == $1 }
            .start(in: db.writer, scheduling: .async(onQueue: .main)) { _ in
            } onChange: { [weak self] unified, open, threads in
                guard let self else { return }
                let accounts = self.accountStore.accounts
                let items = threads.map { t in
                    let idx = accounts.firstIndex { $0.id == t.accountId } ?? 0
                    let hex = accounts.indices.contains(idx) ? accounts[idx].colorHex : nil
                    return WidgetSnapshot.Item(
                        accountId: t.accountId, threadId: t.id, participants: t.participants,
                        subject: t.subject, snippet: t.snippet, lastDate: t.lastDate,
                        isUnread: t.isUnread, isOpen: t.isOpen,
                        colorHex: hex ?? AccountPalette.defaultHex(index: idx))
                }
                WidgetSnapshotStore.save(WidgetSnapshot(generatedAt: .now, unifiedUnread: unified,
                                                        openUnread: open, threads: items))
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
            }
    }
    #endif

    private func pushAccountEmails() async {
        let emails = Dictionary(uniqueKeysWithValues: accountStore.accounts.map { ($0.id, $0.email) })
        await outbox.updateAccountEmails(emails)
    }

    // MARK: - Accounts

    func addAccount() { addAccount(reconnecting: nil) }

    /// Re-runs sign-in for an account whose token Google rejected; the store
    /// swaps the tokens in place, so nothing is re-downloaded.
    func reconnect(_ account: Account) { addAccount(reconnecting: account.email) }

    private func addAccount(reconnecting email: String?) {
        // No client ID yet — collect it first; the setup sheet calls back
        // into this method once one is saved.
        guard Config.isConfigured else {
            showClientSetup = true
            return
        }
        Task {
            do {
                try await accountStore.addAccount(loginHint: email)
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
        if mailbox == nil { navigate(to: .unified) }
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

    // MARK: - Labels

    /// The user-made labels of each account, name-sorted, for the context
    /// menu. System labels (INBOX, STARRED, CATEGORY_*…) are handled by the
    /// dedicated toggles and left out.
    @Published private(set) var userLabels: [String: [GmailClient.GLabel]] = [:]
    private var labelsLoadedAt: [String: Date] = [:]
    /// Set to ask for a label name; `move` also drops the thread from the
    /// inbox once the label is on.
    @Published var newLabelPrompt: (thread: MailThread, move: Bool)?
    @Published var newLabelName = ""

    /// Fetches the label list once per account (and again after an hour, or
    /// when `force`d — after creating one). One small request per account.
    func loadLabels(force: Bool = false) {
        for account in accountStore.accounts {
            if !force, let at = labelsLoadedAt[account.id], Date().timeIntervalSince(at) < 3600 { continue }
            labelsLoadedAt[account.id] = Date()
            let client = accountStore.client(for: account.id)
            Task { [weak self] in
                guard let labels = try? await client.listLabels() else { return }
                let user = labels
                    .filter { $0.type == "user" && $0.name.caseInsensitiveCompare("Open") != .orderedSame }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                await MainActor.run { self?.userLabels[account.id] = user }
            }
        }
    }

    /// Every label currently on the thread — read synchronously (it's a
    /// handful of rows by primary key) so the menu can show check marks.
    func labelIds(of thread: MailThread) -> Set<String> {
        let ids = (try? db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT labelId FROM thread_label WHERE accountId = ? AND threadId = ?",
                                arguments: [thread.accountId, thread.id])
        }) ?? []
        return Set(ids)
    }

    /// Puts one label on or takes it off, with undo. INBOX and the Open label
    /// route through their dedicated actions so the lists react the same way
    /// they do to a hotkey.
    func setLabel(_ labelId: String, on: Bool, for thread: MailThread) {
        if labelId == GmailLabels.inbox {
            if on { unarchive(thread) } else { archive(thread) }
            return
        }
        if labelId == GmailLabels.unread { markRead(thread, read: !on); return }
        if labelId == GmailLabels.starred, thread.isStarred != on { toggleStar(thread); return }
        let name = userLabels[thread.accountId]?.first { $0.id == labelId }?.name
            ?? labelId.capitalized
        pushUndo(on ? "Add \(name)" : "Remove \(name)") { [weak self] in
            guard let self else { return }
            Task {
                await self.syncEngine.modifyThread(accountId: thread.accountId, threadId: thread.id,
                                                   add: on ? [] : [labelId], remove: on ? [labelId] : [])
            }
        }
        ThreadListModel.noteUserAction()
        Task {
            await syncEngine.modifyThread(accountId: thread.accountId, threadId: thread.id,
                                          add: on ? [labelId] : [], remove: on ? [] : [labelId])
        }
    }

    /// Back to the inbox from Archived (or anywhere else).
    func unarchive(_ thread: MailThread) {
        pushUndo("Move to Inbox") { [weak self] in
            guard let self else { return }
            Task { await self.syncEngine.archive(accountId: thread.accountId, threadId: thread.id) }
        }
        ThreadListModel.noteUserAction()
        Task { await syncEngine.unarchive(accountId: thread.accountId, threadId: thread.id, restoreOpen: false) }
    }

    /// Gmail's "move to folder": the label goes on and the thread leaves the
    /// inbox in one step.
    func move(_ thread: MailThread, toLabel labelId: String) {
        let wasOpen = thread.isOpen
        var remove = [GmailLabels.inbox]
        ThreadListModel.hideEverywhere(thread.key)
        pushUndo("Move") { [weak self] in
            guard let self else { return }
            Task {
                await self.syncEngine.modifyThread(accountId: thread.accountId, threadId: thread.id,
                                                   add: [], remove: [labelId])
                await self.syncEngine.unarchive(accountId: thread.accountId, threadId: thread.id,
                                                restoreOpen: wasOpen)
            }
        }
        Task {
            // Archiving also clears Open, same as the archive action.
            if let openId = await syncEngine.openLabel(accountId: thread.accountId) { remove.append(openId) }
            await syncEngine.modifyThread(accountId: thread.accountId, threadId: thread.id,
                                          add: [labelId], remove: remove)
        }
    }

    func promptNewLabel(for thread: MailThread, move: Bool) {
        newLabelName = ""
        newLabelPrompt = (thread, move)
    }

    /// Creates the label the prompt asked for, then applies it (or moves the
    /// thread into it).
    func createLabelFromPrompt() {
        guard let prompt = newLabelPrompt else { return }
        let name = newLabelName.trimmingCharacters(in: .whitespaces)
        newLabelPrompt = nil
        newLabelName = ""
        guard !name.isEmpty else { return }
        let client = accountStore.client(for: prompt.thread.accountId)
        Task { [weak self] in
            do {
                let label = try await client.createLabel(name: name)
                guard let self else { return }
                await MainActor.run {
                    self.loadLabels(force: true)
                    if prompt.move { self.move(prompt.thread, toLabel: label.id) }
                    else { self.setLabel(label.id, on: true, for: prompt.thread) }
                }
            } catch {
                await MainActor.run { self?.lastError = "Couldn't create label: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Thread actions

    func archive(_ thread: MailThread) {
        ThreadListModel.hideEverywhere(thread.key)
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
        ThreadListModel.noteUserAction()
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
        ThreadListModel.noteUserAction()
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
        // Open/closed lists are disjoint, so wherever it's showing, it leaves.
        ThreadListModel.hideEverywhere(thread.key)
        Task { await syncEngine.setOpen(accountId: thread.accountId, threadId: thread.id, open: !wasOpen) }
    }

    // MARK: - Keyboard navigation

    func selectNext(in threads: [MailThread]) {
        guard !threads.isEmpty else { return }
        readerSlideForward = true
        guard let sel = selectedThread,
              let idx = threads.firstIndex(where: { $0.key == sel.key }) else {
            withAnimation(CWT.nav) { selectedThread = threads.first }
            return
        }
        if idx + 1 < threads.count {
            withAnimation(CWT.nav) { selectedThread = threads[idx + 1] }
        }
    }

    func selectPrevious(in threads: [MailThread]) {
        guard !threads.isEmpty else { return }
        guard let sel = selectedThread,
              let idx = threads.firstIndex(where: { $0.key == sel.key }) else {
            readerSlideForward = true
            withAnimation(CWT.nav) { selectedThread = threads.first }
            return
        }
        if idx > 0 {
            readerSlideForward = false
            withAnimation(CWT.nav) { selectedThread = threads[idx - 1] }
        }
    }

    /// Set by an arrow-key column hop: the newly focused column should select
    /// its top thread the moment its list becomes the active one (the column
    /// consumes this from its `focused` change — the hop itself can't reach
    /// the destination column's list, which lives in the column's view).
    var selectTopOnFocus = false

    /// Left/right arrows: hop focus to the neighboring board column, landing
    /// on its top email.
    func focusColumn(offset: Int) {
        let columns = order.boardItems.map(\.filter)
        guard !columns.isEmpty else { return }
        let destination: MailboxFilter?
        if let current = mailbox {
            if let idx = columns.firstIndex(of: current) {
                let next = idx + offset
                guard columns.indices.contains(next) else { return }
                destination = columns[next]
            } else if offset > 0 {
                // A stand-in column (an account, a box kept off the board)
                // sits at the far left, so only a step right leads anywhere.
                destination = columns.first
            } else {
                return
            }
        } else {
            // From the board home, either arrow steps into the strip at its
            // near end: right focuses the first column, left the last.
            destination = offset > 0 ? columns.first : columns.last
        }
        selectTopOnFocus = true
        navigate(to: destination)
    }

    /// Warm the reader's page cache for the threads next to `thread` in the
    /// active list, so e / j / k land on an already-rendered page.
    func prefetchNeighbors(of thread: MailThread) {
        let threads = activeList?.threads ?? []
        guard let idx = threads.firstIndex(where: { $0.key == thread.key }) else { return }
        for offset in [1, -1, 2] {
            let i = idx + offset
            if threads.indices.contains(i) {
                ThreadDetailModel.prefetch(db: db, thread: threads[i])
            }
        }
    }

    /// Archive the selection and advance to the next thread (Superhuman "e").
    func archiveSelected(in threads: [MailThread]) {
        guard let sel = selectedThread else { return }
        let idx = threads.firstIndex { $0.key == sel.key }
        archive(sel)
        if let idx {
            if idx + 1 < threads.count {
                readerSlideForward = true
                withAnimation(CWT.nav) { selectedThread = threads[idx + 1] }
            } else if idx > 0 {
                readerSlideForward = false
                withAnimation(CWT.nav) { selectedThread = threads[idx - 1] }
            } else {
                withAnimation(CWT.nav) { selectedThread = nil }
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
        Task { await persistDraft(d) }
    }

    /// Writes the draft to Gmail and returns the ids it lives under now —
    /// the message id changes on every update, so autosave feeds the result
    /// back into the open composer. nil when the save failed. `quiet` skips
    /// the toast and the immediate re-sync (autosave ticks).
    @discardableResult
    func persistDraft(_ d: ComposeDraft, quiet: Bool = false) async -> (draftId: String, messageId: String)? {
        do {
            let raw = MimeBuilder.build(
                fromEmail: accountEmail(d.accountId),
                to: d.to, cc: d.cc, bcc: d.bcc,
                subject: d.subject, bodyText: d.body, bodyHTML: d.bodyHTML,
                quotedText: d.quotedText, quotedHTML: d.quotedHTML,
                attachments: d.attachments,
                inReplyTo: d.inReplyTo, references: d.references)
            let client = accountStore.client(for: d.accountId)
            var result: (draftId: String, messageId: String)?
            if !d.gmailDraftId.isEmpty {
                result = try await client.updateDraft(
                    draftId: d.gmailDraftId, raw: raw, threadId: d.threadId)
            }
            if result == nil, !d.draftMessageId.isEmpty {
                result = try await client.updateDraft(
                    messageId: d.draftMessageId, raw: raw, threadId: d.threadId)
            }
            if result == nil {
                result = try await client.createDraft(raw: raw, threadId: d.threadId)
            }
            if !quiet {
                flash("Draft saved")
                syncNow()
            }
            return result
        } catch {
            lastError = "Save draft failed: \(error.localizedDescription)"
            return nil
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

    /// Opens the unsubscribe sheet and fires the unsubscribe right away
    /// (progress → result, no confirmation). The thread is archived once the
    /// unsubscribe actually lands.
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
                                         stage: .working)
        confirmUnsubscribe()
    }

    /// Runs (or retries) the unsubscribe for the open session.
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

    /// Every mailbox change funnels through here so it animates. The canvas
    /// derives all its choreography from `mailbox` — which columns shove
    /// where — so one animated assignment is the whole trick. `thread`, when
    /// given, arrives already selected (a drill-in from a column row, or a
    /// widget tap).
    func navigate(to box: MailboxFilter?, selecting thread: MailThread? = nil) {
        guard box != mailbox else {
            if let thread { select(thread) }
            return
        }
        readerSlideForward = true
        if box == nil { activeList = nil }
        withAnimation(CWT.nav) {
            mailbox = box
            selectedThread = thread
        }
    }

    /// Animated selection change: the reader slides the way you moved,
    /// judged from where the two threads sit in the visible list.
    func select(_ thread: MailThread?) {
        let threads = activeList?.threads ?? []
        if let sel = selectedThread, let new = thread,
           let a = threads.firstIndex(where: { $0.key == sel.key }),
           let b = threads.firstIndex(where: { $0.key == new.key }) {
            readerSlideForward = b >= a
        } else {
            readerSlideForward = true
        }
        withAnimation(CWT.nav) { selectedThread = thread }
    }

    /// Open one thread full-width in a given mailbox. From the board this is a
    /// drill-in: the column you clicked becomes the window, and Escape brings
    /// the board back.
    func open(_ thread: MailThread, in filter: MailboxFilter) {
        navigate(to: filter, selecting: thread)
    }

    /// Straight back to the board from wherever you are — reading an email
    /// included. The reader closes and the columns slide home in one motion.
    func escape() {
        if mailbox != nil { navigate(to: nil) }
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
