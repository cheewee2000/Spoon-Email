import Foundation
import GRDB

@MainActor
public final class AccountStore: ObservableObject {
    @Published public private(set) var accounts: [Account] = []

    private let db: AppDatabase
    public let tokens: TokenManager
    private let config: GoogleOAuthConfig

    public init(db: AppDatabase, config: GoogleOAuthConfig) {
        self.db = db
        self.config = config
        self.tokens = TokenManager(config: config)
        load()
    }

    public func load() {
        accounts = (try? db.writer.read { db in
            try Account.order(Column("sortOrder")).fetchAll(db)
        }) ?? []
    }

    /// Runs the full interactive add-account flow.
    @discardableResult
    public func addAccount() async throws -> Account {
        let oauthTokens = try await GoogleOAuth.signIn(config: config)
        let accountId = UUID().uuidString
        try await tokens.store(oauthTokens, accountId: accountId)

        let client = GmailClient(accountId: accountId, tokens: tokens)
        let profile = try await client.profile()

        // Re-adding an existing address replaces its tokens instead of duplicating
        if let existing = accounts.first(where: { $0.email == profile.emailAddress }) {
            await tokens.remove(accountId: accountId)
            try await tokens.store(oauthTokens, accountId: existing.id)
            return existing
        }

        let account = Account(id: accountId, email: profile.emailAddress, sortOrder: accounts.count)
        try await db.writer.write { db in
            try account.insert(db)
        }
        load()
        return account
    }

    public func toggleUnified(_ account: Account) async {
        _ = try? await db.writer.write { db in
            try db.execute(sql: "UPDATE account SET includeInUnified = NOT includeInUnified WHERE id = ?",
                           arguments: [account.id])
        }
        load()
    }

    /// `nil` puts the account back on the built-in palette.
    public func setColor(_ account: Account, hex: String?) async {
        _ = try? await db.writer.write { db in
            try db.execute(sql: "UPDATE account SET colorHex = ? WHERE id = ?",
                           arguments: [hex, account.id])
        }
        load()
    }

    public func removeAccount(_ account: Account) async {
        await tokens.remove(accountId: account.id)
        _ = try? await db.writer.write { db in
            try Account.deleteOne(db, key: account.id)
        }
        load()
    }

    public func client(for accountId: String) -> GmailClient {
        GmailClient(accountId: accountId, tokens: tokens)
    }
}
