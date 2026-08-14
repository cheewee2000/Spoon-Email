import Foundation
import Contacts
import CryptoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A picture for an email address, looked up once and then kept.
///
/// Three sources, in order of how much they actually say about the sender:
/// the local address book first (a real photo of someone you know, and the
/// lookup never leaves the device), then Gravatar for the address itself,
/// then the sending domain's icon — which is what makes a wall of newsletters
/// scannable. Anything not found is remembered as *not found*, or every scroll
/// past a plain sender would re-ask the network.
///
/// The last two are outbound requests carrying a hash of the address and the
/// sender's domain; nothing is sent for addresses already answered by
/// Contacts or by the cache.
actor AvatarStore {
    static let shared = AvatarStore()

    /// Value `nil` means "looked up, has none".
    private var memory: [String: Data?] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let dir: URL

    /// Nobody's face is 800KB, and the bytes get base64'd into the rendered
    /// page — anything bigger is a favicon service handing back a banner.
    private static let maxBytes = 800 * 1024

    /// A miss is worth re-checking eventually: contacts gain photos, and
    /// domains put up an icon. Not often, though — this is a per-address timer.
    private static let missTTL: TimeInterval = 14 * 24 * 3600

    /// Shared-mailbox domains: the address belongs to a person, so the
    /// domain's icon says nothing about them. (It would also paint every
    /// personal sender with the same Gmail logo.)
    private static let freemail: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "hotmail.com",
        "outlook.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "mail.com",
        "fastmail.com", "hey.com", "zoho.com", "yandex.com", "qq.com", "163.com",
    ]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Image bytes for an address, or nil if it hasn't got a picture.
    func avatar(for rawEmail: String) async -> Data? {
        let email = Self.normalize(rawEmail)
        guard email.contains("@") else { return nil }
        if let hit = memory[email] { return hit }
        if let disk = readDisk(email) { memory[email] = disk; return disk }
        if let running = inFlight[email] { return await running.value }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.lookUp(email)
        }
        inFlight[email] = task
        let found = await task.value
        inFlight[email] = nil
        memory[email] = found
        writeDisk(email, found)
        return found
    }

    /// Convenience for the rendered conversation, which needs a `src`.
    func dataURI(for email: String) async -> String? {
        guard let bytes = await avatar(for: email) else { return nil }
        return "data:\(Self.mime(bytes));base64,\(bytes.base64EncodedString())"
    }

    // MARK: - Sources

    private func lookUp(_ email: String) async -> Data? {
        if let photo = await contactPhoto(email) { return photo }
        if let gravatar = await fetch(Self.gravatarURL(email)) { return gravatar }
        if let domain = Self.domain(of: email), !Self.freemail.contains(domain),
           let icon = await fetch(Self.faviconURL(domain)) {
            return icon
        }
        return nil
    }

    private var contactsAsked = false
    private var contactsAllowed = false

    private func contactPhoto(_ email: String) async -> Data? {
        guard await contactsAuthorized() else { return nil }
        return await Task.detached(priority: .utility) { () -> Data? in
            let store = CNContactStore()
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
            let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
            return matches.compactMap(\.thumbnailImageData).first
        }.value
    }

    private func contactsAuthorized() async -> Bool {
        if contactsAsked { return contactsAllowed }
        contactsAsked = true
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted:
            contactsAllowed = false
        case .notDetermined:
            // The prompt fires on the first avatar the app needs, which is the
            // moment it can actually explain itself. Declining just drops this
            // source; the web ones still run.
            contactsAllowed = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        default:
            contactsAllowed = true   // .authorized, and .limited on newer systems
        }
        return contactsAllowed
    }

    private func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty, data.count <= Self.maxBytes,
              Self.isImage(data) else { return nil }
        return data
    }

    // MARK: - URLs

    /// `d=404` is the whole point: without it Gravatar always answers with a
    /// generated blob, and every sender on earth would appear to "have one".
    private static func gravatarURL(_ email: String) -> URL {
        let hash = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=128&d=404")!
    }

    /// DuckDuckGo's icon service rather than Google's: this one 404s on a
    /// domain it doesn't know, where Google hands back a generic globe that
    /// can't be told apart from a real icon.
    private static func faviconURL(_ domain: String) -> URL {
        URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico")!
    }

    // MARK: - Disk

    private func path(_ email: String) -> URL {
        let hash = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hash + ".img")
    }

    /// Outer nil: nothing on disk. Inner nil: a remembered miss.
    private func readDisk(_ email: String) -> Data?? {
        let url = path(email)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.isEmpty {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(modified) < Self.missTTL else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return .some(nil)
        }
        return .some(data)
    }

    private func writeDisk(_ email: String, _ data: Data?) {
        try? (data ?? Data()).write(to: path(email), options: .atomic)
    }

    // MARK: - Bytes

    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Headers hand these over as "Name <addr>" often enough to be worth
        // catching here rather than at every call site.
        if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
            s = String(s[s.index(after: open)..<close])
        }
        return s
    }

    private static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let host = String(email[email.index(after: at)...])
        return host.contains(".") ? host : nil
    }

    private static func isImage(_ data: Data) -> Bool {
        #if os(macOS)
        return NSImage(data: data) != nil
        #else
        return UIImage(data: data) != nil
        #endif
    }

    private static func mime(_ data: Data) -> String {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x89, 0x50]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if head.starts(with: [0x47, 0x49]) { return "image/gif" }
        if head.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        return "image/png"
    }
}
