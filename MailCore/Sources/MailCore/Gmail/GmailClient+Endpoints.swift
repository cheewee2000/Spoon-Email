import Foundation

public extension GmailClient {
    func listThreads(q: String? = nil, labelIds: [String] = [],
                     maxResults: Int = 100, pageToken: String? = nil) async throws -> GThreadList {
        var query: [URLQueryItem] = [.init(name: "maxResults", value: String(maxResults))]
        if let q { query.append(.init(name: "q", value: q)) }
        for l in labelIds { query.append(.init(name: "labelIds", value: l)) }
        if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
        return try await get("threads", query: query)
    }

    func getThread(_ id: String) async throws -> GThread {
        try await get("threads/\(id)", query: [.init(name: "format", value: "full")])
    }

    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        struct Empty: Decodable {}
        var body: [String: Any] = [:]
        if !add.isEmpty { body["addLabelIds"] = add }
        if !remove.isEmpty { body["removeLabelIds"] = remove }
        let _: Empty = try await post("threads/\(id)/modify", json: body)
    }

    func listHistory(startHistoryId: String, pageToken: String? = nil) async throws -> GHistoryList {
        var query: [URLQueryItem] = [.init(name: "startHistoryId", value: startHistoryId),
                                     .init(name: "maxResults", value: "500")]
        if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
        return try await get("history", query: query)
    }

    /// Sends a raw RFC 2822 message; returns the new Gmail message.
    func send(raw: Data, threadId: String?) async throws -> GMessageMin {
        var body: [String: Any] = ["raw": GmailClient.base64URLEncode(raw)]
        if let threadId { body["threadId"] = threadId }
        return try await post("messages/send", json: body)
    }

    /// Server-side search (for results beyond the local cache).
    func searchMessageIds(q: String, maxResults: Int = 25) async throws -> [GMessageMin] {
        struct MsgList: Decodable { let messages: [GMessageMin]? }
        let list: MsgList = try await get("messages", query: [
            .init(name: "q", value: q),
            .init(name: "maxResults", value: String(maxResults)),
        ])
        return list.messages ?? []
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
