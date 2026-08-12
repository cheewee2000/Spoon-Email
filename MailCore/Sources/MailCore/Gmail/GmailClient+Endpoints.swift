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

    func getMessage(_ id: String) async throws -> GMessage {
        try await get("messages/\(id)", query: [.init(name: "format", value: "full")])
    }

    /// Downloads one attachment's bytes. Gmail attachment ids rotate, so we
    /// re-fetch the message and locate the part by its stable partId.
    func downloadAttachment(messageId: String, partId: String) async throws -> Data {
        struct AttachmentBody: Decodable { let data: String? }
        let message = try await getMessage(messageId)
        var attachmentId: String?
        func walk(_ p: GPart?) {
            guard let p else { return }
            if p.partId == partId { attachmentId = p.body?.attachmentId }
            p.parts?.forEach { walk($0) }
        }
        walk(message.payload)
        guard let attachmentId else { throw MailError.http(404, "attachment part not found") }
        let body: AttachmentBody = try await get("messages/\(messageId)/attachments/\(attachmentId)")
        guard let data = body.data, let decoded = MimeParser.base64URLDecode(data) else {
            throw MailError.http(422, "attachment data undecodable")
        }
        return decoded
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
