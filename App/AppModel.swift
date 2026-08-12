import Foundation
import SwiftUI
import MailCore

@MainActor
final class AppModel: ObservableObject {
    let db: AppDatabase
    let accountStore: AccountStore
    let syncEngine: SyncEngine

    @Published var lastError: String?
    @Published var syncStatus: String?

    private static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]

    init() {
        do {
            db = try AppDatabase.open()
        } catch {
            fatalError("Cannot open database: \(error)")
        }
        accountStore = AccountStore(db: db, config: GoogleOAuthConfig(clientID: Config.googleClientID))
        syncEngine = SyncEngine(db: db, tokens: accountStore.tokens)
        Task {
            await syncEngine.setStatusHandler { [weak self] status in
                Task { @MainActor in self?.syncStatus = status }
            }
            syncNow()
        }
    }

    // MARK: - Accounts

    func addAccount() {
        Task {
            do {
                try await accountStore.addAccount()
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
        return Self.palette[idx % Self.palette.count]
    }

    // MARK: - Sync

    func syncNow() {
        let accounts = accountStore.accounts
        guard !accounts.isEmpty else { return }
        Task { await syncEngine.syncAll(accounts: accounts) }
    }

    // MARK: - Thread actions

    func archive(_ thread: MailThread) {
        Task { await syncEngine.archive(accountId: thread.accountId, threadId: thread.id) }
    }

    func markRead(_ thread: MailThread, read: Bool) {
        Task { await syncEngine.markRead(accountId: thread.accountId, threadId: thread.id, read: read) }
    }

    func toggleStar(_ thread: MailThread) {
        Task { await syncEngine.toggleStar(accountId: thread.accountId, threadId: thread.id, starred: !thread.isStarred) }
    }
}
