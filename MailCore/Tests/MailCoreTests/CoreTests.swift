import XCTest
@testable import MailCore

final class CoreTests: XCTestCase {

    // MARK: - MIME builder

    func testMimeBuilderHeadersAndBody() throws {
        let data = MimeBuilder.build(
            fromEmail: "me@example.com",
            to: "you@example.com", cc: "", bcc: "",
            subject: "Hello", bodyText: "Line one\nLine two",
            inReplyTo: "<abc@mail.gmail.com>", references: "<abc@mail.gmail.com>")
        let raw = String(data: data, encoding: .utf8)!
        XCTAssertTrue(raw.contains("From: me@example.com\r\n"))
        XCTAssertTrue(raw.contains("To: you@example.com\r\n"))
        XCTAssertTrue(raw.contains("Subject: Hello\r\n"))
        XCTAssertTrue(raw.contains("In-Reply-To: <abc@mail.gmail.com>\r\n"))
        XCTAssertTrue(raw.contains("multipart/alternative"))
        XCTAssertFalse(raw.contains("Cc:"))

        // The plain-text part decodes back to the original body
        let b64 = Data("Line one\nLine two".utf8).base64EncodedString()
        XCTAssertTrue(raw.replacingOccurrences(of: "\r\n", with: "").contains(b64))
    }

    func testMimeBuilderEncodesUnicodeSubject() {
        let data = MimeBuilder.build(
            fromEmail: "a@b.c", to: "d@e.f", cc: "", bcc: "",
            subject: "héllo ✨", bodyText: "x", inReplyTo: "", references: "")
        let raw = String(data: data, encoding: .utf8)!
        XCTAssertTrue(raw.contains("Subject: =?UTF-8?B?"))
    }

    // MARK: - Address parsing

    func testParseAddress() {
        let a = MimeParser.parseAddress("Ann Example <ann@example.com>")
        XCTAssertEqual(a.name, "Ann Example")
        XCTAssertEqual(a.email, "ann@example.com")

        let b = MimeParser.parseAddress("bob@example.com")
        XCTAssertEqual(b.email, "bob@example.com")
        XCTAssertEqual(b.name, "bob")

        let c = MimeParser.parseAddress("\"Last, First\" <lf@example.com>")
        XCTAssertEqual(c.email, "lf@example.com")
    }

    // MARK: - Category derivation

    func testCategoryPrecedence() {
        XCTAssertEqual(ThreadCategory.derive(from: ["INBOX", "CATEGORY_PERSONAL"]), "important")
        XCTAssertEqual(ThreadCategory.derive(from: ["INBOX", "CATEGORY_PROMOTIONS", "STARRED"]), "important")
        XCTAssertEqual(ThreadCategory.derive(from: ["INBOX", "CATEGORY_PROMOTIONS"]), "newsletters")
        XCTAssertEqual(ThreadCategory.derive(from: ["INBOX", "CATEGORY_UPDATES"]), "updates")
        XCTAssertEqual(ThreadCategory.derive(from: ["INBOX", "CATEGORY_SOCIAL"]), "other")
        XCTAssertEqual(ThreadCategory.derive(from: ["INBOX"]), "important")
    }

    // MARK: - Sync store + FTS + mailbox queries

    func testStoreThreadAndQuery() async throws {
        let db = try AppDatabase.inMemory()
        let account = Account(id: "acc1", email: "me@example.com")
        try await db.writer.write { db in try account.insert(db) }

        let json = """
        {
          "id": "t1",
          "messages": [{
            "id": "m1", "threadId": "t1",
            "labelIds": ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"],
            "snippet": "Big sale on widgets",
            "internalDate": "1723300000000",
            "payload": {
              "mimeType": "text/plain",
              "headers": [
                {"name": "From", "value": "Shop <shop@example.com>"},
                {"name": "To", "value": "me@example.com"},
                {"name": "Subject", "value": "Widget sale"},
                {"name": "Message-ID", "value": "<m1@shop>"}
              ],
              "body": {"data": "\(GmailClient.base64URLEncode(Data("Buy widgets now".utf8)))"}
            }
          }]
        }
        """
        let gThread = try JSONDecoder().decode(GThread.self, from: Data(json.utf8))

        let tokens = TokenManager(config: GoogleOAuthConfig(clientID: "x.apps.googleusercontent.com"))
        let engine = SyncEngine(db: db, tokens: tokens)
        try await engine.store(gThread: gThread, accountId: "acc1")

        let threads = try await db.writer.read { db in try MailboxFilter.unified.fetch(db) }
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].subject, "Widget sale")
        XCTAssertTrue(threads[0].isUnread)
        XCTAssertEqual(threads[0].category, "newsletters")

        let newsletters = try await db.writer.read { db in try MailboxFilter.newsletters.fetch(db) }
        XCTAssertEqual(newsletters.count, 1)
        let important = try await db.writer.read { db in try MailboxFilter.important.fetch(db) }
        XCTAssertTrue(important.isEmpty)

        // FTS finds it by body text
        let hits = try await db.writer.read { db in
            try MailThread.fetchAll(db, sql: """
                SELECT t.* FROM thread t WHERE EXISTS (
                    SELECT 1 FROM message_fts
                    WHERE message_fts MATCH ?
                      AND message_fts.accountId = t.accountId
                      AND message_fts.threadId = t.id
                )
                """, arguments: ["\"widgets\"*"])
        }
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: - Quoted-text splitting

    func testSplitQuoted() {
        let (main, quoted) = MimeParser.splitQuoted(
            "Thanks, sounds good!\n\nOn Aug 11, 2026, Bob <b@x.com> wrote:\n> earlier\n> text")
        XCTAssertEqual(main, "Thanks, sounds good!\n")
        XCTAssertTrue(quoted?.hasPrefix("On Aug 11") ?? false)

        let none = MimeParser.splitQuoted("Just a plain message.\nNo quotes here.")
        XCTAssertNil(none.quoted)

        // A leading quote marker on line 0 is not a trail — keep everything visible
        let leading = MimeParser.splitQuoted("> whole message is a quote\n> more")
        XCTAssertNil(leading.quoted)
    }

    // MARK: - Unsubscribe header parsing

    func testUnsubscribeParse() {
        let links = Unsubscriber.parse(
            header: "<mailto:unsub@list.com?subject=stop>, <https://list.com/u?id=1>",
            postHeader: "List-Unsubscribe=One-Click")
        XCTAssertEqual(links?.https?.host, "list.com")
        XCTAssertEqual(links?.mailto?.scheme, "mailto")
        XCTAssertTrue(links?.oneClick ?? false)
        XCTAssertNil(Unsubscriber.parse(header: "", postHeader: ""))
    }

    // MARK: - Block rules

    func testBlockRuleMatching() {
        let email = BlockRule(pattern: "spam@foo.com", kind: "email")
        XCTAssertTrue(email.matches(email: "Spam@Foo.com"))
        XCTAssertFalse(email.matches(email: "other@foo.com"))

        let domain = BlockRule(pattern: "foo.com", kind: "domain")
        XCTAssertTrue(domain.matches(email: "anyone@foo.com"))
        XCTAssertFalse(domain.matches(email: "anyone@notfoo.com.evil.net"))
    }

    // MARK: - Optimistic mutations

    func testModifyThreadUpdatesLocallyAndQueuesOp() async throws {
        let db = try AppDatabase.inMemory()
        let account = Account(id: "acc1", email: "me@example.com")
        try await db.writer.write { db in
            try account.insert(db)
            try MailThread(accountId: "acc1", id: "t1", subject: "s", snippet: "",
                           lastDate: Date(), isUnread: true, isStarred: false,
                           participants: "", messageCount: 1, category: "important",
                           hasDraft: false, hasAttachments: false).insert(db)
            try ThreadLabel(accountId: "acc1", threadId: "t1", labelId: "INBOX").insert(db)
            try ThreadLabel(accountId: "acc1", threadId: "t1", labelId: "UNREAD").insert(db)
        }

        let tokens = TokenManager(config: GoogleOAuthConfig(clientID: "x.apps.googleusercontent.com"))
        let engine = SyncEngine(db: db, tokens: tokens)
        // Archive (replay will fail against the network — the local change and queued op must persist)
        await engine.archive(accountId: "acc1", threadId: "t1")

        let inbox = try await db.writer.read { db in try MailboxFilter.unified.fetch(db) }
        XCTAssertTrue(inbox.isEmpty, "archived thread must leave the inbox immediately")

        let ops = try await db.writer.read { db in try PendingOp.fetchAll(db) }
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].removeLabelIds, "INBOX")
    }
}
