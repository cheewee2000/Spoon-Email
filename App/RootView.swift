import SwiftUI
import MailCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var listModel = ThreadListModel()
    @State private var searchText = ""

    private let syncTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            ThreadListView(listModel: listModel, selection: $model.selectedThread,
                           searchQuery: searchText.isEmpty ? nil : searchText)
                .searchable(text: $searchText, prompt: "Search all mail")
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
        .onAppear {
            listModel.observe(db: model.db, filter: .unified)
        }
        .onChange(of: model.mailbox) {
            searchText = ""
            listModel.observe(db: model.db, filter: model.mailbox ?? .unified)
            model.selectedThread = nil
        }
        .onChange(of: searchText) {
            if searchText.isEmpty {
                listModel.observe(db: model.db, filter: model.mailbox ?? .unified)
            } else {
                listModel.observeSearch(db: model.db, query: searchText)
            }
        }
        .onReceive(syncTimer) { _ in model.syncNow() }
        .sheet(item: $model.draft) { draft in
            ComposeView(draft: draft)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showBlocked) {
            BlockedListView()
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
            if scenePhase == .active { model.syncNow() }
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
        }
        actions.append(PaletteAction("Compose", systemImage: "square.and.pencil", shortcut: "C") {
            model.compose()
        })
        actions.append(PaletteAction("Sync Now", systemImage: "arrow.clockwise", shortcut: "⌘R") {
            model.syncNow()
        })
        if let t = model.selectedThread {
            actions.append(PaletteAction("Unsubscribe", systemImage: "envelope.arrow.triangle.branch") {
                model.unsubscribe(t)
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
        let boxes: [(String, MailboxFilter, String)] = [
            ("Go to Unified Inbox", .unified, "tray.full"),
            ("Go to Important", .important, "star"),
            ("Go to Newsletters", .newsletters, "newspaper"),
            ("Go to Updates", .updates, "bell"),
            ("Go to Other", .other, "tray"),
            ("Go to Drafts", .drafts, "doc.badge.ellipsis"),
            ("Go to Sent", .sent, "paperplane"),
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.mailbox) {
                Section("Inbox") {
                    Label("Unified", systemImage: "tray.full").tag(MailboxFilter.unified)
                    Label("Important", systemImage: "star").tag(MailboxFilter.important)
                    Label("Newsletters", systemImage: "newspaper").tag(MailboxFilter.newsletters)
                    Label("Updates", systemImage: "bell").tag(MailboxFilter.updates)
                    Label("Other", systemImage: "tray").tag(MailboxFilter.other)
                }
                Section("Mail") {
                    Label("Drafts", systemImage: "doc.badge.ellipsis").tag(MailboxFilter.drafts)
                    Label("Sent", systemImage: "paperplane").tag(MailboxFilter.sent)
                }
                AccountsSection(store: model.accountStore, addAccount: model.addAccount)
            }
            Divider()
            HStack {
                Text(model.syncStatus ?? "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(6)
        }
        .navigationTitle("SuperDuperHuman")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        #endif
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
                Button("Undo", action: undo)
                    .keyboardShortcut("z", modifiers: .command)
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
    let addAccount: () -> Void

    var body: some View {
        Section("Accounts") {
            ForEach(store.accounts) { account in
                Label {
                    Text(account.email)
                        .foregroundStyle(account.includeInUnified ? .primary : .secondary)
                } icon: {
                    Image(systemName: account.includeInUnified ? "person.circle" : "person.circle.fill")
                }
                .tag(MailboxFilter.account(account.id))
                .contextMenu {
                    Toggle("Include in Unified Inbox", isOn: Binding(
                        get: { account.includeInUnified },
                        set: { _ in Task { await store.toggleUnified(account) } }
                    ))
                    Divider()
                    Button("Remove Account", role: .destructive) {
                        Task { await store.removeAccount(account) }
                    }
                }
            }
            Button(action: addAccount) {
                Label("Add Account…", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
        }
    }
}
