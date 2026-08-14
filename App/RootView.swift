import SwiftUI
import MailCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var listModel = ThreadListModel()
    @StateObject private var order = SidebarOrder()
    @AppStorage("sidebarExpanded") private var sidebarExpanded = false
    /// Native split-view collapse (toolbar chevron / drag-to-hide). Tracked
    /// here because the board <-> mailbox swap builds a fresh split view each
    /// time, which would otherwise reset the sidebar to visible.
    @AppStorage("sidebarHidden") private var sidebarHidden = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            if model.mailbox == nil {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } detail: {
                    BoardView(order: order)
                }
            } else {
                mailboxWindow
            }
            #else
            // No board on the phone — nine columns don't fit. One mailbox at a
            // time, swiped between, with the rail still a swipe further left.
            NavigationSplitView {
                sidebar
            } detail: {
                // The stack is what arms the pager's NavigationLinks — in a
                // bare split-view detail column they render but do nothing.
                NavigationStack {
                    MailboxPager(order: order)
                }
            }
            #endif
        }
        .railHoverLabel()
        .onAppear {
            installKeyMonitor()
            model.startBackfillIfNeeded()
            #if os(macOS)
            columns = desiredColumns
            #endif
        }
        // macOS only: the phone's pages each hold their own list, and this
        // would restart a query on every swipe.
        #if os(macOS)
        .onChange(of: model.mailbox) {
            searchText = ""
            // The swap just built a fresh split view — re-impose the collapse.
            columns = desiredColumns
            // Board: nothing to observe, and nothing to clear either — the
            // full-width list keeps its last mailbox for when we come back.
            guard let mailbox = model.mailbox else { return }
            listModel.observe(db: model.db, filter: mailbox)
            // Normally a mailbox switch starts you with nothing selected; a
            // drill-in from the board hands over the thread you clicked.
            model.selectedThread = model.pendingSelection
            model.pendingSelection = nil
        }
        .onChange(of: searchText) {
            guard let mailbox = model.mailbox else { return }
            if searchText.isEmpty {
                listModel.observe(db: model.db, filter: mailbox)
            } else {
                listModel.observeSearch(db: model.db, query: searchText)
            }
        }
        .onChange(of: columns) {
            // The user dragged or toggled the sidebar — remember their choice.
            sidebarHidden = (columns == .detailOnly || columns == .doubleColumn)
        }
        .onChange(of: model.focusSearchRequest) {
            // ⌘F on the board opens Unified, and that search field doesn't
            // exist yet on this pass of the run loop — focus it on the next.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                searchFocused = true
            }
        }
        #endif
        .composeWindow()
        #if !os(macOS)
        .sheet(item: $model.draft) { draft in
            ComposeView(draft: draft)
                .environmentObject(model)
        }
        #endif
        .sheet(isPresented: $model.showBlocked) {
            BlockedListView()
                .environmentObject(model)
        }
        .sheet(item: $model.unsubscribe) { session in
            UnsubscribeSheet(session: session)
                .environmentObject(model)
        }
        .overlay(alignment: .top) {
            if model.showPalette {
                CommandPalette(actions: paletteActions, isPresented: $model.showPalette)
                    .padding(.top, 80)
                    .zIndex(10)
            }
        }
        .background {
            Button("") { model.showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .overlay(alignment: .bottom) {
            if let toast = model.undoToast {
                UndoToast(until: toast.until) {
                    model.undoSend()
                } expired: {
                    model.undoToast = nil
                }
                .padding(.bottom, 16)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.syncNow()
                model.startBackfillIfNeeded()
            }
            #if os(iOS)
            // Arm the next wake-up on the way out; iOS only honours a request
            // that exists before the app is suspended.
            if scenePhase == .background { BackgroundRefresh.schedule() }
            #endif
        }
        .alert("Error", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    /// What the current layout should show when the sidebar is hidden: the
    /// board is two columns (sidebar + detail), a mailbox is three.
    private var desiredColumns: NavigationSplitViewVisibility {
        sidebarHidden ? (model.mailbox == nil ? .detailOnly : .doubleColumn) : .all
    }

    /// One mailbox, full width: the list beside the conversation.
    private var mailboxWindow: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } content: {
            ThreadListView(listModel: listModel, selection: $model.selectedThread,
                           searchQuery: searchText.isEmpty ? nil : searchText)
                .searchable(text: $searchText, prompt: "Search all mail")
                .searchFocused($searchFocused)
                .navigationTitle(listModel.filter.title)
                .toolbar {
                    ToolbarItem {
                        Button {
                            model.compose()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("Compose (C)")
                    }
                }
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
                #endif
        } detail: {
            if let thread = model.selectedThread {
                ThreadDetailView(thread: thread)
            } else {
                Text("Select a conversation")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Single-key triage shortcuts, active no matter what has focus (thread
    /// list, message web view) — but never while typing: text fields, the
    /// compose sheet, and the command palette all pass through untouched.
    private func installKeyMonitor() {
        #if os(macOS)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleGlobalKey(event) ? nil : event
        }
        #endif
    }

    #if os(macOS)
    private func handleGlobalKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        guard model.draft == nil, !model.showPalette, !model.showBlocked,
              model.unsubscribe == nil else { return false }
        // Escape backs out toward the board from wherever you are — including
        // out of the search field, which is the one place it beats the text
        // editors below to the keystroke (it's how you abandon a search).
        if event.keyCode == 53 {
            guard model.mailbox != nil else { return false }
            model.escape()
            return true
        }
        // Field editors (search box, any text input) own their keystrokes.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }
        if event.charactersIgnoringModifiers == "c" {
            model.compose()
            return true
        }
        // Everything below acts on the full-width list's selection, which the
        // board doesn't have — its columns each hold their own.
        guard model.mailbox != nil else { return false }
        let threads = listModel.threads
        switch event.charactersIgnoringModifiers {
        case "j": model.selectNext(in: threads)
        case "k": model.selectPrevious(in: threads)
        case "e": model.archiveSelected(in: threads)
        case "u": guard let t = model.selectedThread else { return false }
                  model.markRead(t, read: t.isUnread)
        case "s": guard let t = model.selectedThread else { return false }
                  model.toggleStar(t)
        case "o": guard let t = model.selectedThread else { return false }
                  model.toggleOpen(t)
        case "r": guard let t = model.selectedThread else { return false }
                  model.reply(to: t, all: false)
        case "a": guard let t = model.selectedThread else { return false }
                  model.reply(to: t, all: true)
        case "f": guard let t = model.selectedThread else { return false }
                  model.forward(t)
        default: return false
        }
        return true
    }
    #endif

    private var paletteActions: [PaletteAction] {
        var actions: [PaletteAction] = []
        if let t = model.selectedThread {
            actions.append(PaletteAction("Archive", systemImage: "archivebox", shortcut: "E") {
                model.archiveSelected(in: listModel.threads)
            })
            actions.append(PaletteAction("Reply", systemImage: "arrowshape.turn.up.left", shortcut: "R") {
                model.reply(to: t, all: false)
            })
            actions.append(PaletteAction("Reply All", systemImage: "arrowshape.turn.up.left.2", shortcut: "A") {
                model.reply(to: t, all: true)
            })
            actions.append(PaletteAction("Forward", systemImage: "arrowshape.turn.up.right", shortcut: "F") {
                model.forward(t)
            })
            actions.append(PaletteAction(t.isUnread ? "Mark Read" : "Mark Unread",
                                         systemImage: "envelope.badge", shortcut: "U") {
                model.markRead(t, read: t.isUnread)
            })
            actions.append(PaletteAction(t.isStarred ? "Unstar" : "Star",
                                         systemImage: "star", shortcut: "S") {
                model.toggleStar(t)
            })
            actions.append(PaletteAction(t.isOpen ? "Remove from Open" : "Mark Open",
                                         systemImage: "clock", shortcut: "O") {
                model.toggleOpen(t)
            })
        }
        actions.append(PaletteAction("Compose", systemImage: "square.and.pencil", shortcut: "C") {
            model.compose()
        })
        actions.append(PaletteAction("Sync Now", systemImage: "arrow.clockwise", shortcut: "⌘R") {
            model.syncNow()
        })
        if let t = model.selectedThread {
            actions.append(PaletteAction("Unsubscribe", systemImage: "envelope.arrow.triangle.branch") {
                model.beginUnsubscribe(t)
            })
            actions.append(PaletteAction("Block Sender", systemImage: "person.slash") {
                model.block(t, wholeDomain: false)
            })
            actions.append(PaletteAction("Block Domain", systemImage: "globe.badge.chevron.backward") {
                model.block(t, wholeDomain: true)
            })
        }
        actions.append(PaletteAction("Manage Blocked Senders", systemImage: "hand.raised") {
            model.showBlocked = true
        })
        actions.append(PaletteAction("Go to All Mailboxes", systemImage: "rectangle.split.3x1",
                                     shortcut: "esc") {
            model.selectedThread = nil
            model.mailbox = nil
        })
        let boxes: [(String, MailboxFilter, String)] = [
            ("Go to Unified Inbox", .unified, "tray.full"),
            ("Go to Important", .important, "star"),
            ("Go to Newsletters", .newsletters, "newspaper"),
            ("Go to Updates", .updates, "bell"),
            ("Go to Other", .other, "tray"),
            ("Go to Open", .open, "clock"),
            ("Go to Drafts", .drafts, "doc.badge.ellipsis"),
            ("Go to Sent", .sent, "paperplane"),
            ("Go to Archived", .archived, "archivebox"),
            ("Go to Blocked", .blocked, "hand.raised"),
        ]
        for (title, box, icon) in boxes {
            actions.append(PaletteAction(title, systemImage: icon) { model.mailbox = box })
        }
        for account in model.accountStore.accounts {
            actions.append(PaletteAction("Go to \(account.email)", systemImage: "person.circle") {
                model.mailbox = .account(account.id)
            })
        }
        return actions
    }

    /// Collapsed, it's icons only — every name in here is revealed by
    /// `railTitle`, which pops the moment the pointer lands rather than after
    /// the system's tooltip delay. Expanded, those same names sit on their
    /// rows and the footer gets room to spell out the sync status. Section
    /// headers stay dropped either way: their text is the only thing that
    /// would hold the rail wide when it's meant to be narrow. The mailboxes
    /// are one flat, draggable group, since fixed Inbox/Mail sections would
    /// only be a wall for a reorder to bump into.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.mailbox) {
                Section {
                    // The way home, for anyone who doesn't reach for Escape.
                    // Untagged, so the list can't select it — the board's
                    // "selection" is the absence of a mailbox.
                    Button {
                        model.selectedThread = nil
                        model.mailbox = nil
                    } label: {
                        RailIcon("All Mailboxes", systemImage: "rectangle.split.3x1")
                    }
                    .buttonStyle(.plain)
                    .moveDisabled(true)
                    .listRowBackground(model.mailbox == nil
                                       ? Color.accentColor.opacity(0.25) : Color.clear)
                }
                Section {
                    ForEach(order.items) { item in
                        RailIcon(item.title,
                                 systemImage: item.systemImage,
                                 badge: item == .open ? model.openUnreadCount : 0)
                            .tag(item.filter)
                            .contextMenu {
                                Toggle("Show in Main View", isOn: Binding(
                                    get: { order.isOnBoard(item) },
                                    set: { order.setOnBoard(item, $0) }
                                ))
                                if item == .blocked {
                                    Divider()
                                    // The list shows what the rules caught;
                                    // this is where the rules themselves live.
                                    Button("Manage Blocked…") { model.showBlocked = true }
                                }
                            }
                    }
                    .onMove { from, to in order.moveItems(from: from, to: to) }
                }
                AccountsSection(store: model.accountStore,
                                order: order,
                                accountColor: model.accountColor,
                                addAccount: model.addAccount,
                                defaultComposeId: model.defaultComposeAccount?.id,
                                setDefaultCompose: model.setDefaultComposeAccount,
                                setColor: model.setAccountColor)
            }
            Divider()
            footer
        }
        .environment(\.railExpanded, sidebarExpanded)
        .navigationTitle("Spoon")
        #if os(macOS)
        .navigationSplitViewColumnWidth(sidebarExpanded ? RailWidth.expanded : RailWidth.collapsed)
        #endif
    }

    private var statusLine: String {
        model.syncStatus
            ?? "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
    }

    /// Logo, sync state, and the width toggle. Narrow, the status has nowhere
    /// to go, so the logo carries it on hover; wide, it's just written out.
    @ViewBuilder private var footer: some View {
        let logo = Image("Logo").resizable().frame(width: 18, height: 18)
        if sidebarExpanded {
            HStack(spacing: 8) {
                logo
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                expandToggle
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                expandToggle
                logo.railTitle(statusLine)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { sidebarExpanded.toggle() }
        } label: {
            Image(systemName: sidebarExpanded ? "chevron.left.2" : "chevron.right.2")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, minHeight: 22)
        }
        .buttonStyle(.plain)
        .help(sidebarExpanded ? "Collapse Sidebar (⌥⌘S)" : "Expand Sidebar (⌥⌘S)")
        .keyboardShortcut("s", modifiers: [.option, .command])
    }
}

struct UndoToast: View {
    let until: Date
    let undo: () -> Void
    let expired: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 12) {
                Text("Sending in \(remaining)s")
                // ⌘Z lives on the Edit ▸ Undo menu item now, which routes to
                // the pending send while this toast is up.
                Button("Undo", action: undo)
                    .help("Undo Send (⌘Z)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .onChange(of: context.date) {
                if context.date >= until { expired() }
            }
        }
    }
}

struct AccountsSection: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var order: SidebarOrder
    let accountColor: (String) -> Color
    let addAccount: () -> Void
    /// The address new mail leaves from — resolved, so it's marked even when
    /// nothing was pinned and the first account is standing in.
    let defaultComposeId: String?
    let setDefaultCompose: (String) -> Void
    let setColor: (Account, String?) -> Void
    @Environment(\.railExpanded) private var expanded

    var body: some View {
        let accounts = order.sorted(store.accounts)
        Section {
            ForEach(accounts) { account in
                // Same color the account's rows wear in the thread list — with
                // the address gone, color and the filled/hollow ring are what
                // tell two accounts apart until you hover one.
                RailIcon(account.email,
                         systemImage: account.includeInUnified ? "person.circle.fill" : "person.circle",
                         tint: accountColor(account.id),
                         trailingSymbol: account.id == defaultComposeId ? "square.and.pencil" : nil)
                .tag(MailboxFilter.account(account.id))
                .contextMenu {
                    Toggle("Include in Unified Inbox", isOn: Binding(
                        get: { account.includeInUnified },
                        set: { _ in Task { await store.toggleUnified(account) } }
                    ))
                    // Replies always leave from the account that received the
                    // mail; this only steers brand-new messages.
                    Toggle("Send New Mail From This Account", isOn: Binding(
                        get: { account.id == defaultComposeId },
                        set: { _ in setDefaultCompose(account.id) }
                    ))
                    Divider()
                    Menu("Color") {
                        ForEach(AccountPalette.swatches) { swatch in
                            Button {
                                setColor(account, swatch.hex)
                            } label: {
                                // A filled dot rather than a plain checkmark:
                                // the point of the menu is which color, and a
                                // menu of twelve identical rows of text isn't
                                // that. The current one keeps the check too.
                                Label {
                                    Text(swatch.name)
                                } icon: {
                                    Image(systemName: account.colorHex?.caseInsensitiveCompare(swatch.hex) == .orderedSame
                                          ? "checkmark.circle.fill" : "circle.fill")
                                        .foregroundStyle(swatch.color)
                                }
                            }
                        }
                        Divider()
                        Button {
                            setColor(account, nil)
                        } label: {
                            Label("Automatic",
                                  systemImage: account.colorHex == nil ? "checkmark" : "wand.and.stars")
                        }
                    }
                    Divider()
                    Button("Remove Account", role: .destructive) {
                        Task { await store.removeAccount(account) }
                    }
                }
            }
            .onMove { from, to in order.moveAccounts(store.accounts, from: from, to: to) }
            Button(action: addAccount) {
                if expanded {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle").imageScale(.large).frame(width: 22)
                        Text("Add Account…")
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 22)
                } else {
                    Image(systemName: "plus.circle")
                        .imageScale(.large)
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
            }
            .buttonStyle(.plain)
            // Not draggable — it isn't a destination, it's the way to make one.
            .moveDisabled(true)
            .railTitle("Add Account…")
        }
    }
}
