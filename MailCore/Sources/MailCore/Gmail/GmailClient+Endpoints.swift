import Foundation

public extension GmailClient {
    func listThreads(q: String? = nil, labelIds: [String] = [],
                     maxResults: Int = 100, pageToken: String? = nil,
                     includeSpamTrash: Bool = false) async throws -> GThreadList {
        var query: [URLQueryItem] = [.init(name: "maxResults", value: String(maxResults))]
        if includeSpamTrash { query.append(.init(name: "includeSpamTrash", value: "true")) }
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
        var body: [String: Any] = ["raw": raw.base64URLEncoded()]
        if let threadId { body["threadId"] = threadId }
        return try await post("messages/send", json: body)
    }

    func getMessage(_ id: String) async throws -> GMessage {
        try await get("messages/\(id)", query: [.init(name: "format", value: "full")])
    }

    /// Downloads one attachment's bytes. Gmail attachment ids rotate, so we
    /// re-fetch the message and locate the part by its stable partId.
    func downloadAttachment(messageId: String, partId: String) async throws -> Data {
        guard let data = try await downloadAttachments(messageId: messageId,
                                                       partIds: [partId])[partId] else {
            throw MailError.http(404, "attachment part not found")
        }
        return data
    }

    /// Downloads several parts of the same message on one message fetch —
    /// a body full of inline images would otherwise re-fetch the whole
    /// message once per picture.
    func downloadAttachments(messageId: String, partIds: [String]) async throws -> [String: Data] {
        struct AttachmentBody: Decodable { let data: String? }
        guard !partIds.isEmpty else { return [:] }
        let message = try await getMessage(messageId)
        let wanted = Set(partIds)
        var parts: [String: GBody] = [:]
        func walk(_ p: GPart?) {
            guard let p else { return }
            if let id = p.partId, wanted.contains(id), let body = p.body { parts[id] = body }
            p.parts?.forEach { walk($0) }
        }
        walk(message.payload)

        var out: [String: Data] = [:]
        for (partId, body) in parts {
            // Small parts come back with their bytes already inline; only the
            // ones Gmail parked behind an id need the extra round trip.
            if let inline = body.data, let decoded = MimeParser.base64URLDecode(inline) {
                out[partId] = decoded
            } else if let attachmentId = body.attachmentId {
                let fetched: AttachmentBody = try await get("messages/\(messageId)/attachments/\(attachmentId)")
                guard let raw = fetched.data, let decoded = MimeParser.base64URLDecode(raw) else {
                    throw MailError.http(422, "attachment data undecodable")
                }
                out[partId] = decoded
            }
        }
        return out
    }

    struct GLabel: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        /// "system" for INBOX/STARRED/CATEGORY_*…, "user" for the ones you made.
        public let type: String?
    }

    func listLabels() async throws -> [GLabel] {
        struct LabelList: Decodable { let labels: [GLabel]? }
        let list: LabelList = try await get("labels")
        return list.labels ?? []
    }

    func createLabel(name: String) async throws -> GLabel {
        try await post("labels", json: [
            "name": name,
            "labelListVisibility": "labelShow",
            "messageListVisibility": "show",
        ])
    }

    struct GDraft: Decodable, Sendable {
        let id: String
        let message: GMessageMin?
    }

    /// Gmail draft ids aren't stored locally; drafts are found by the
    /// *message* id they wrap.
    func draftId(forMessageId messageId: String) async throws -> String? {
        struct DraftList: Decodable { let drafts: [GDraft]?; let nextPageToken: String? }
        var pageToken: String?
        repeat {
            var query: [URLQueryItem] = [.init(name: "maxResults", value: "100")]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let list: DraftList = try await get("drafts", query: query)
            if let hit = (list.drafts ?? []).first(where: { $0.message?.id == messageId }) {
                return hit.id
            }
            pageToken = list.nextPageToken
        } while pageToken != nil
        return nil
    }

    /// Deletes the Gmail draft wrapping the given draft *message* id.
    /// Used after an edited draft is sent so the stale draft doesn't linger.
    /// A 404 means the draft is already gone (deleted twice, or the local
    /// message id went stale after an autosave) — that's the outcome we
    /// wanted, so it's not an error.
    func deleteDraft(messageId: String) async throws {
        do {
            if let id = try await draftId(forMessageId: messageId) {
                try await delete("drafts/\(id)")
            } else {
                // No draft wrapper found — trash the underlying message, which
                // discards the draft too (never fail silently on other errors:
                // a missed delete resurrects the draft on the next sync).
                struct Empty: Decodable {}
                let _: Empty = try await post("messages/\(messageId)/trash", json: [:])
            }
        } catch MailError.http(404, _) {}
    }

    private struct DraftResponse: Decodable {
        struct M: Decodable { let id: String }
        let id: String
        let message: M
    }

    /// Creates a draft and returns where it lives: the draft id is stable
    /// across edits, the message id changes on every update.
    func createDraft(raw: Data, threadId: String?) async throws -> (draftId: String, messageId: String) {
        var message: [String: Any] = ["raw": raw.base64URLEncoded()]
        if let threadId { message["threadId"] = threadId }
        let r: DraftResponse = try await post("drafts", json: ["message": message])
        return (r.id, r.message.id)
    }

    /// Replaces the content of the draft wrapping `messageId`.
    /// Returns nil if that draft no longer exists (caller should create).
    func updateDraft(messageId: String, raw: Data, threadId: String?) async throws -> (draftId: String, messageId: String)? {
        guard let id = try await draftId(forMessageId: messageId) else { return nil }
        return try await updateDraft(draftId: id, raw: raw, threadId: threadId)
    }

    /// Replaces a draft's content by its stable draft id — the fast path for
    /// autosave, which would otherwise re-list all drafts on every tick.
    /// Returns the new message id, or nil if the draft was deleted meanwhile.
    func updateDraft(draftId: String, raw: Data, threadId: String?) async throws -> (draftId: String, messageId: String)? {
        var message: [String: Any] = ["raw": raw.base64URLEncoded()]
        if let threadId { message["threadId"] = threadId }
        do {
            let r: DraftResponse = try await put("drafts/\(draftId)", json: ["message": message])
            return (r.id, r.message.id)
        } catch MailError.http(404, _) {
            return nil
        }
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
}

extension Data {
    /// RFC 4648 §5 base64url, unpadded — what Gmail's `raw` field and PKCE want.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
