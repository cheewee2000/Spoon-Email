import Foundation
import MailCore

/// Bytes for the images a message shows inline. Gmail hands attachments over
/// one HTTP fetch at a time, so a signature logo would otherwise re-download
/// every time the thread is opened; results are kept on disk and reused.
actor InlineImageCache {
    static let shared = InlineImageCache()

    /// A single picture big enough to blow past this is not something a body
    /// realistically shows inline, and it would be inlined as base64 into the
    /// rendered page — skip it and leave the reference unresolved.
    private static let maxBytes = 8 * 1024 * 1024

    private var memory: [String: Data] = [:]
    private var inFlight: [String: Task<[String: Data], Never>] = [:]
    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("InlineImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Fetches every requested part of one message, keyed by partId. Parts
    /// already cached cost nothing; the rest ride along on a single message
    /// fetch.
    func data(for attachments: [Attachment], client: GmailClient) async -> [String: Data] {
        guard let first = attachments.first else { return [:] }
        var out: [String: Data] = [:]
        var missing: [Attachment] = []
        for att in attachments {
            if let hit = cached(att) {
                out[att.partId] = hit
            } else {
                missing.append(att)
            }
        }
        guard !missing.isEmpty else { return out }

        let messageId = first.messageId
        let partIds = missing.map(\.partId).sorted()
        let key = "\(first.accountId)|\(messageId)|\(partIds.joined(separator: ","))"
        // Two thread-detail renders in a row (the observation fires again the
        // moment the read flag is written) would otherwise download twice.
        let task: Task<[String: Data], Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            task = Task {
                (try? await client.downloadAttachments(messageId: messageId, partIds: partIds)) ?? [:]
            }
            inFlight[key] = task
        }
        let fetched = await task.value
        inFlight[key] = nil

        for att in missing {
            guard let data = fetched[att.partId], data.count <= Self.maxBytes else { continue }
            store(att, data: data)
            out[att.partId] = data
        }
        return out
    }

    private func cached(_ att: Attachment) -> Data? {
        let key = key(att)
        if let hit = memory[key] { return hit }
        guard let onDisk = try? Data(contentsOf: file(key)) else { return nil }
        memory[key] = onDisk
        return onDisk
    }

    private func store(_ att: Attachment, data: Data) {
        let key = key(att)
        memory[key] = data
        try? data.write(to: file(key))
    }

    private func key(_ att: Attachment) -> String {
        "\(att.accountId)-\(att.messageId)-\(att.partId)"
            .replacingOccurrences(of: "/", with: "_")
    }

    private func file(_ key: String) -> URL {
        dir.appendingPathComponent(key)
    }
}

/// Remote images WebKit loaded but couldn't draw (see `GIFRepair`): fetched
/// again here, re-encoded, and handed back as a `data:` URI for the page to
/// swap in. Results — misses included — are remembered for the session.
actor ImageRepair {
    static let shared = ImageRepair()

    private static let maxBytes = 20 * 1024 * 1024
    /// No cookies: a newsletter image host has no business seeing the app's.
    private let session = URLSession(configuration: .ephemeral)
    private var done: [URL: String?] = [:]

    func dataURI(for url: URL) async -> String? {
        if let hit = done[url] { return hit }
        var uri: String?
        if let (data, _) = try? await session.data(from: url), data.count <= Self.maxBytes,
           let fixed = GIFRepair.repaired(data) {
            uri = "data:image/gif;base64,\(fixed.base64EncodedString())"
        }
        done[url] = uri
        return uri
    }
}
