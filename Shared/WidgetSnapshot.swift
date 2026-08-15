import Foundation

/// What the home-screen widget shows, written by the app after every sync
/// and read by the widget extension. A flat file in the shared App Group
/// container rather than the database itself: the widget never has to
/// open SQLite, and the app decides exactly what leaves its sandbox.
struct WidgetSnapshot: Codable {
    struct Item: Codable, Hashable {
        var accountId: String
        var threadId: String
        var participants: String
        var subject: String
        var snippet: String
        var lastDate: Date
        var isUnread: Bool
        var isOpen: Bool
        /// The account's color, "#RRGGBB".
        var colorHex: String
    }

    var generatedAt: Date
    var unifiedUnread: Int
    var openUnread: Int
    /// Newest Unified threads, most recent first.
    var threads: [Item]

    static let empty = WidgetSnapshot(generatedAt: .distantPast, unifiedUnread: 0,
                                      openUnread: 0, threads: [])
}

enum WidgetSnapshotStore {
    /// Must match the entitlement on both the app and the widget extension.
    static let appGroup = "group.com.cwandt.spoon"
    static let widgetKind = "SpoonInbox"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// Deep links the widget hands the app.
enum SpoonURL {
    static let scheme = "spoon"

    static func mailbox(_ name: String) -> URL { URL(string: "\(scheme)://mailbox/\(name)")! }
    static func thread(accountId: String, threadId: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "thread"
        c.path = "/\(accountId)/\(threadId)"
        return c.url!
    }
}
