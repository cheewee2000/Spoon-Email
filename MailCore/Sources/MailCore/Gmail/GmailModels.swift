import Foundation

// MARK: - Gmail REST resource DTOs

public struct GThreadList: Decodable, Sendable {
    public let threads: [GThreadStub]?
    public let nextPageToken: String?
}

public struct GThreadStub: Decodable, Sendable {
    public let id: String
}

public struct GThread: Decodable, Sendable {
    public let id: String
    public let messages: [GMessage]?
}

public struct GMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let internalDate: String?
    public let payload: GPart?
}

public struct GPart: Decodable, Sendable {
    public let partId: String?
    public let mimeType: String?
    public let filename: String?
    public let headers: [GHeader]?
    public let body: GBody?
    public let parts: [GPart]?
}

public struct GHeader: Decodable, Sendable {
    public let name: String
    public let value: String
}

public struct GBody: Decodable, Sendable {
    public let data: String?
    public let size: Int?
    public let attachmentId: String?
}

public struct GHistoryList: Decodable, Sendable {
    public let history: [GHistory]?
    public let historyId: String?
    public let nextPageToken: String?
}

public struct GHistory: Decodable, Sendable {
    public let messagesAdded: [GMessageWrap]?
    public let messagesDeleted: [GMessageWrap]?
    public let labelsAdded: [GLabelChange]?
    public let labelsRemoved: [GLabelChange]?
}

public struct GMessageWrap: Decodable, Sendable {
    public let message: GMessageMin
}

public struct GLabelChange: Decodable, Sendable {
    public let message: GMessageMin
}

public struct GMessageMin: Decodable, Sendable {
    public let id: String
    public let threadId: String
}

// MARK: - MIME payload parsing

public enum MimeParser {
    public static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    static func header(_ payload: GPart?, _ name: String) -> String {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    /// Walks the part tree and returns (html, plainText) bodies.
    static func bodies(of part: GPart?) -> (html: String?, text: String?) {
        var html: String?
        var text: String?
        func walk(_ p: GPart?) {
            guard let p else { return }
            let mime = p.mimeType ?? ""
            let isAttachment = !(p.filename ?? "").isEmpty
            if !isAttachment, let data = p.body?.data, let decoded = base64URLDecode(data),
               let str = String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .isoLatin1) {
                if mime == "text/html", html == nil { html = str }
                if mime == "text/plain", text == nil { text = str }
            }
            p.parts?.forEach { walk($0) }
        }
        walk(part)
        return (html, text)
    }

    /// "Ann Example <ann@example.com>" → ("Ann Example", "ann@example.com")
    public static func parseAddress(_ raw: String) -> (name: String, email: String) {
        guard let lt = raw.lastIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt else {
            let email = raw.trimmingCharacters(in: .whitespaces)
            return (email.components(separatedBy: "@").first ?? email, email)
        }
        let email = String(raw[raw.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        var name = String(raw[..<lt]).trimmingCharacters(in: .whitespaces)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (name.isEmpty ? email : name, email)
    }

    /// Converts a Gmail API message into our local Message, its label ids,
    /// and its attachment metadata.
    public static func localMessage(from g: GMessage, accountId: String) -> (Message, [String], [Attachment]) {
        let from = parseAddress(header(g.payload, "From"))
        let (html, text) = bodies(of: g.payload)
        let dateMs = Double(g.internalDate ?? "0") ?? 0
        let msg = Message(
            accountId: accountId,
            id: g.id,
            threadId: g.threadId,
            fromName: from.name,
            fromEmail: from.email,
            toList: header(g.payload, "To"),
            ccList: header(g.payload, "Cc"),
            date: Date(timeIntervalSince1970: dateMs / 1000),
            snippet: decodeEntities(g.snippet ?? ""),
            bodyHTML: html,
            bodyText: text,
            isUnread: g.labelIds?.contains(GmailLabels.unread) ?? false,
            messageIdHeader: header(g.payload, "Message-ID").isEmpty
                ? header(g.payload, "Message-Id")
                : header(g.payload, "Message-ID"),
            referencesHeader: header(g.payload, "References"),
            listUnsubscribe: header(g.payload, "List-Unsubscribe"),
            listUnsubscribePost: header(g.payload, "List-Unsubscribe-Post"),
            isDraft: g.labelIds?.contains(GmailLabels.draft) ?? false
        )
        return (msg, g.labelIds ?? [], attachments(of: g, accountId: accountId))
    }

    /// Parts with a filename are attachments (inline cid images excluded
    /// only when they have no filename).
    static func attachments(of g: GMessage, accountId: String) -> [Attachment] {
        var found: [Attachment] = []
        func walk(_ p: GPart?) {
            guard let p else { return }
            if let name = p.filename, !name.isEmpty {
                found.append(Attachment(
                    accountId: accountId, messageId: g.id,
                    partId: p.partId ?? String(found.count),
                    filename: name,
                    mimeType: p.mimeType ?? "application/octet-stream",
                    size: p.body?.size ?? 0))
            }
            p.parts?.forEach { walk($0) }
        }
        walk(g.payload)
        return found
    }

    /// Splits plain text into (new content, quoted trail) at the first
    /// quote marker, so replies can collapse the history.
    public static func splitQuoted(_ text: String) -> (main: String, quoted: String?) {
        let lines = text.components(separatedBy: "\n")
        var cut: Int?
        var sawContent = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            let isMarker = t.hasPrefix(">")
                || (t.hasPrefix("On ") && t.hasSuffix("wrote:"))
                || t.hasPrefix("-----Original Message-----")
                || t.hasPrefix("---------- Forwarded message")
            if isMarker {
                // Only fold when there's real content above the quote trail
                if sawContent { cut = i }
                break
            }
            if !t.isEmpty { sawContent = true }
        }
        guard let cut else { return (text, nil) }
        return (lines[..<cut].joined(separator: "\n"),
                lines[cut...].joined(separator: "\n"))
    }

    public static func subject(of g: GMessage) -> String {
        header(g.payload, "Subject")
    }

    /// Crude HTML → searchable/preview text.
    public static func stripHTML(_ html: String) -> String {
        var s = html
        // drop <style>/<script> blocks entirely
        for tag in ["style", "script", "head"] {
            while let r = s.range(of: "<\(tag)[\\s\\S]*?</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(r)
            }
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

// MARK: - Split-inbox category

public enum ThreadCategory {
    /// Precedence: personal/starred/important → important, then promotions,
    /// updates, social/forums. Uncategorized mail counts as important.
    public static func derive(from labelIds: Set<String>) -> String {
        if labelIds.contains(GmailLabels.categoryPersonal)
            || labelIds.contains(GmailLabels.starred)
            || labelIds.contains(GmailLabels.important) {
            return "important"
        }
        if labelIds.contains(GmailLabels.categoryPromotions) { return "newsletters" }
        if labelIds.contains(GmailLabels.categoryUpdates) { return "updates" }
        if labelIds.contains(GmailLabels.categorySocial)
            || labelIds.contains(GmailLabels.categoryForums) {
            return "other"
        }
        return "important"
    }
}
