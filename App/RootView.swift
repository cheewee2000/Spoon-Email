import SwiftUI
import MailCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var mailbox: MailboxFilter? = .unified
    @State private var selectedThread: MailThread?
    @StateObject private var listModel = ThreadListModel()

    private let syncTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            ThreadListView(listModel: listModel, selection: $selectedThread)
                .navigationTitle(listModel.filter.title)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
                #endif
        } detail: {
            if let thread = selectedThread {
                ThreadDetailView(thread: thread)
            } else {
                Text("Select a conversation")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            listModel.observe(db: model.db, filter: .unified)
        }
        .onChange(of: mailbox) {
            listModel.observe(db: model.db, filter: mailbox ?? .unified)
            selectedThread = nil
        }
        .onReceive(syncTimer) { _ in model.syncNow() }
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $mailbox) {
                Section("Inbox") {
                    Label("Unified", systemImage: "tray.full").tag(MailboxFilter.unified)
                    Label("Important", systemImage: "star").tag(MailboxFilter.important)
                    Label("Newsletters", systemImage: "newspaper").tag(MailboxFilter.newsletters)
                    Label("Updates", systemImage: "bell").tag(MailboxFilter.updates)
                    Label("Other", systemImage: "tray").tag(MailboxFilter.other)
                }
                Section("Mail") {
                    Label("Sent", systemImage: "paperplane").tag(MailboxFilter.sent)
                }
                AccountsSection(store: model.accountStore, addAccount: model.addAccount)
            }
            if let status = model.syncStatus {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(6)
            }
        }
        .navigationTitle("SuperDuperHuman")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        #endif
    }
}

struct AccountsSection: View {
    @ObservedObject var store: AccountStore
    let addAccount: () -> Void

    var body: some View {
        Section("Accounts") {
            ForEach(store.accounts) { account in
                Label(account.email, systemImage: "person.circle")
                    .tag(MailboxFilter.account(account.id))
                    .contextMenu {
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
