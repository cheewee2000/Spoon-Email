import XCTest
@testable import MailCore

final class CoreTests: XCTestCase {

    // MARK: - Address lists

    func testSplitKeepsQuotedCommasTogether() {
        XCTAssertEqual(
            AddressList.split("\"Doe, John\" <j@x.com>, jo@y.com, \"Ann\" <a@z.com>"),
            ["\"Doe, John\" <j@x.com>", "jo@y.com", "\"Ann\" <a@z.com>"],
            "a comma inside a quoted display name is part of the name, not a separator")
        XCTAssertEqual(AddressList.split(""), [])
        XCTAssertEqual(AddressList.split("  , ,jo@y.com,"), ["jo@y.com"])
    }

    func testEmailIdentityIgnoresDisplayNameAndCase() {
        XCTAssertEqual(AddressList.email(of: "Jo Smith <Jo@X.com>"), "jo@x.com")
        XCTAssertEqual(AddressList.email(of: "  JO@x.com "), "jo@x.com")
        XCTAssertEqual(AddressList.email(of: "\"Doe, John\" <j@x.com>"), "j@x.com")
    }

    func testReplyAllPutsEachPersonInExactlyOneField() {
        // The sender is also in To, and one recipient appears in both To and
        // Cc — spelled differently every time.
        let result = AddressList.replyRecipients(
            to: ["Ann <ann@x.com>"],
            others: AddressList.split("ANN@x.com, Bob <bob@y.com>, me@z.com")
                + AddressList.split("bob@y.com, Cat <cat@w.com>"),
            me: "me@z.com")

        XCTAssertEqual(result.to, ["Ann <ann@x.com>"])
        XCTAssertEqual(result.cc, ["Bob <bob@y.com>", "Cat <cat@w.com>"],
                       "nobody in To may reappear in Cc, and nobody twice in Cc")
        XCTAssertFalse(result.cc.contains { AddressList.email(of: $0) == "me@z.com" },
                       "the account replying is never one of its own recipients")
    }

    func testReplyToYourOwnMessageKeepsItsRecipients() {
        let result = AddressList.replyRecipients(
            to: AddressList.split("Ann <ann@x.com>, bob@y.com"),
            others: AddressList.split("Ann <ann@x.com>, bob@y.com"),
            me: "me@z.com")
        XCTAssertEqual(result.to, ["Ann <ann@x.com>", "bob@y.com"])
        XCTAssertEqual(result.cc, [], "everyone was already in To")
    }

    func testReplyingOnlyToYourselfStillHasARecipient() {
        let result = AddressList.replyRecipients(
            to: ["me@z.com"], others: [], me: "me@z.com")
        XCTAssertEqual(result.to, ["me@z.com"],
                       "dropping yourself here would leave nowhere to send")
    }

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

        // Text parts travel quoted-printable and decode back to the body
        XCTAssertTrue(raw.contains("Content-Transfer-Encoding: quoted-printable\r\n\r\nLine one\r\nLine two\r\n"))
        XCTAssertFalse(raw.contains("Content-Transfer-Encoding: base64"))
    }

    func testMimeBuilderMessageIDUsesSenderDomain() throws {
        let data = MimeBuilder.build(
            fromEmail: "me@example.com", to: "you@example.com", cc: "", bcc: "",
            subject: "Hi", bodyText: "x", inReplyTo: "", references: "")
        let raw = String(data: data, encoding: .utf8)!
        let line = try XCTUnwrap(raw.components(separatedBy: "\r\n").first { $0.hasPrefix("Message-ID: <") })
        XCTAssertTrue(line.hasSuffix("@example.com>"), line)
        XCTAssertFalse(raw.contains("spoon.local"))
        XCTAssertEqual(MimeBuilder.messageIDDomain("Name <me@cwandt.com>"), "cwandt.com")
    }

    func testQuotedPrintableEncoding() {
        // Non-ASCII, '=', and trailing whitespace are escaped; newlines are
        // hard CRLF breaks; nothing passes through unchanged that shouldn't.
        XCTAssertEqual(MimeBuilder.quotedPrintable("caf\u{E9} a=b \nnext"),
                       "caf=C3=A9 a=3Db=20\r\nnext")
        XCTAssertEqual(MimeBuilder.quotedPrintable("tab\t\nx"), "tab=09\r\nx")
        // Long lines soft-wrap so no encoded line exceeds 76 characters, and
        // the decoded text is unchanged.
        let long = String(repeating: "abcdefghij", count: 20) + " \u{2728} end"
        let encoded = MimeBuilder.quotedPrintable(long)
        for line in encoded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76, line)
        }
        XCTAssertEqual(qpDecode(encoded), long)
    }

    /// A rich reply ships its formatting in the HTML part while the text/plain
    /// part stays readable for clients that only take plain text.
    func testMimeBuilderUsesRichBodyForHTMLPart() throws {
        let data = MimeBuilder.build(
            fromEmail: "me@example.com",
            to: "you@example.com", cc: "", bcc: "",
            subject: "Hi", bodyText: "bold word",
            bodyHTML: "<div><b>bold</b> word</div>",
            quotedText: "> earlier", quotedHTML: "<blockquote>earlier</blockquote>",
            inReplyTo: "", references: "")
        let raw = String(data: data, encoding: .utf8)!

        let html = "<div style=\"font-family:-apple-system,sans-serif;font-size:14px\">"
            + "<div><b>bold</b> word</div></div><blockquote>earlier</blockquote>"
        XCTAssertTrue(qpDecode(raw).contains(html),
                      "HTML part must carry the composed rich text as-is")
        XCTAssertTrue(qpDecode(raw).contains("bold word\n\n> earlier"),
                      "plain part must still be the plain body plus quote")
    }

    /// An inline image wraps the alternative body in a multipart/related whose
    /// image part answers to the cid the HTML points at.
    func testMimeBuilderNestsInlineImagesInRelatedPart() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let image = ComposeAttachment(id: "img-1@sdh", filename: "shot.png",
                                      mimeType: "image/png", data: bytes)
        let data = MimeBuilder.build(
            fromEmail: "me@example.com", to: "you@example.com", cc: "", bcc: "",
            subject: "Hi", bodyText: "look",
            bodyHTML: "<div><img src=\"cid:img-1@sdh\"></div>",
            attachments: [image], inReplyTo: "", references: "")
        let raw = String(data: data, encoding: .utf8)!
        let lines = raw.components(separatedBy: "\r\n")

        let related = try XCTUnwrap(lines.first { $0.hasPrefix("Content-Type: multipart/related") })
        let relatedBoundary = try XCTUnwrap(
            related.components(separatedBy: "boundary=\"").last?.components(separatedBy: "\"").first)
        XCTAssertTrue(related.contains("type=\"multipart/alternative\""))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Content-Type: multipart/alternative") },
                      "text+html must still be offered as alternatives, nested inside related")
        XCTAssertTrue(lines.contains("Content-ID: <img-1@sdh>"))
        XCTAssertTrue(lines.contains("Content-Disposition: inline; filename=\"shot.png\""))
        XCTAssertTrue(lines.contains(bytes.base64EncodedString()))
        XCTAssertEqual(lines.last, "--\(relatedBoundary)--", "related part must be closed last")
    }

    /// A reply to a thread that was parked in "Open" ends the wait, so it
    /// belongs back in the unified inbox.
    func testReplyPullsOpenThreadBackIntoUnified() async throws {
        let db = try AppDatabase.inMemory()
        let account = Account(id: "acc1", email: "me@example.com", openLabelId: "Label_open")
        try await db.writer.write { db in try account.insert(db) }
        let tokens = TokenManager(config: GoogleOAuthConfig(clientID: "x.apps.googleusercontent.com"))
        let engine = SyncEngine(db: db, tokens: tokens)

        func message(id: String, date: Int, unread: Bool) -> String {
            """
            {
              "id": "\(id)", "threadId": "t1",
              "labelIds": ["INBOX", "Label_open"\(unread ? ", \"UNREAD\"" : "")],
              "snippet": "about the invoice",
              "internalDate": "\(date)",
              "payload": {
                "mimeType": "text/plain",
                "headers": [
                  {"name": "From", "value": "Ann <ann@example.com>"},
                  {"name": "To", "value": "me@example.com"},
                  {"name": "Subject", "value": "Invoice"}
                ],
                "body": {"data": "\(GmailClient.base64URLEncode(Data("about the invoice".utf8)))"}
              }
            }
            """
        }
        func thread(_ messages: [String]) throws -> GThread {
            try JSONDecoder().decode(GThread.self, from: Data(
                "{\"id\": \"t1\", \"messages\": [\(messages.joined(separator: ","))]}".utf8))
        }

        // Parked in Open, nothing unread: hidden from unified, listed in Open.
        try await engine.store(gThread: thread([message(id: "m1", date: 1723300000000, unread: false)]),
                               accountId: "acc1", detectNewMail: true)
        var unified = try await db.writer.read { db in try MailboxFilter.unified.fetch(db) }
        var open = try await db.writer.read { db in try MailboxFilter.open.fetch(db) }
        XCTAssertTrue(unified.isEmpty)
        XCTAssertEqual(open.count, 1)

        // Ann replies.
        try await engine.store(gThread: thread([message(id: "m1", date: 1723300000000, unread: false),
                                                message(id: "m2", date: 1723400000000, unread: true)]),
                               accountId: "acc1", detectNewMail: true)
        unified = try await db.writer.read { db in try MailboxFilter.unified.fetch(db) }
        open = try await db.writer.read { db in try MailboxFilter.open.fetch(db) }
        XCTAssertEqual(unified.count, 1, "a replied-to thread returns to the inbox")
        XCTAssertTrue(open.isEmpty, "and stops waiting in Open")

        // The label has to come off on the server too, or the next sync
        // would park it again.
        let ops = try await db.writer.read { db in try PendingOp.fetchAll(db) }
        XCTAssertTrue(ops.contains { $0.removeLabelIds.contains("Label_open") })
    }

    /// The outbox holds a scheduled send until it's due, so an inline image
    /// has to survive the trip through SQLite.
    func testOutboxRoundTripsAttachments() async throws {
        let db = try AppDatabase.inMemory()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let item = OutboxItem(
            accountId: "acc1", threadId: nil,
            toList: "you@example.com", ccList: "", bccList: "",
            subject: "Hi", bodyText: "look", bodyHTML: "<div><img src=\"cid:img-1@sdh\"></div>",
            attachments: [ComposeAttachment(id: "img-1@sdh", filename: "shot.png",
                                            mimeType: "image/png", data: bytes)],
            sendAt: Date())
        try await db.writer.write { db in try item.save(db) }

        let loaded = try await db.writer.read { db in try OutboxItem.fetchOne(db) }
        XCTAssertEqual(loaded?.attachments.count, 1)
        XCTAssertEqual(loaded?.attachments.first?.data, bytes)
        XCTAssertEqual(loaded?.attachments.first?.id, "img-1@sdh")
    }

    /// No images means no extra nesting — plain multipart/alternative.
    func testMimeBuilderKeepsFlatStructureWithoutAttachments() throws {
        let data = MimeBuilder.build(
            fromEmail: "me@example.com", to: "you@example.com", cc: "", bcc: "",
            subject: "Hi", bodyText: "look", inReplyTo: "", references: "")
        let raw = String(data: data, encoding: .utf8)!
        XCTAssertFalse(raw.contains("multipart/related"))
    }

    /// Drafts written before rich compose have no HTML; they still escape.
    func testMimeBuilderFallsBackToEscapedPlainText() throws {
        let data = MimeBuilder.build(
            fromEmail: "me@example.com", to: "you@example.com", cc: "", bcc: "",
            subject: "Hi", bodyText: "a < b\nnext", inReplyTo: "", references: "")
        let raw = String(data: data, encoding: .utf8)!
        let html = "<div style=\"font-family:-apple-system,sans-serif;font-size:14px\">"
            + "a &lt; b<br>next</div>"
        XCTAssertTrue(qpDecode(raw).contains(html))
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
            try MailSearch.threads(db, match: MailSearch.ftsQuery("widgets")!)
        }
        XCTAssertEqual(hits.count, 1)
    }

    /// Pasted pictures often arrive with a Content-ID and no filename; without
    /// a part row for them the body's `cid:` reference can never be resolved.
    func testInlineImageWithoutFilenameIsKept() throws {
        let json = """
        {
          "id": "m1", "threadId": "t1",
          "payload": {
            "mimeType": "multipart/related",
            "parts": [
              {"partId": "0", "mimeType": "text/html",
               "body": {"data": "\(GmailClient.base64URLEncode(Data("<img src=\"cid:logo@x\">".utf8)))"}},
              {"partId": "1", "mimeType": "image/png", "filename": "",
               "headers": [{"name": "Content-ID", "value": "<logo@x>"}],
               "body": {"attachmentId": "a1", "size": 12}},
              {"partId": "2", "mimeType": "application/pdf", "filename": "spec.pdf",
               "body": {"attachmentId": "a2", "size": 34}}
            ]
          }
        }
        """
        let message = try JSONDecoder().decode(GMessage.self, from: Data(json.utf8))
        let parts = MimeParser.attachments(of: message, accountId: "acc1")
        XCTAssertEqual(parts.count, 2)
        let inline = try XCTUnwrap(parts.first { $0.partId == "1" })
        XCTAssertEqual(inline.contentId, "logo@x")
        XCTAssertEqual(inline.filename, "image-1.png")
        // A container part with no Content-ID is still not an attachment.
        XCTAssertNil(parts.first { $0.mimeType == "multipart/related" })
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

    /// Blocked mail is archived on arrival, so the Blocked mailbox is the only
    /// place it can still be found — by rule, not by label.
    func testBlockedMailboxListsWhatTheRulesCaught() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            try Account(id: "acc1", email: "me@example.com").insert(db)
            for (threadId, sender) in [("t1", "Spam@Foo.com"),
                                       ("t2", "anyone@bar.com"),
                                       ("t3", "friend@example.org")] {
                try MailThread(accountId: "acc1", id: threadId, subject: threadId, snippet: "",
                               lastDate: Date(), isUnread: false, isStarred: false,
                               participants: "", messageCount: 1, category: "other",
                               hasDraft: false, hasAttachments: false).insert(db)
                try Message(accountId: "acc1", id: "m-\(threadId)", threadId: threadId,
                            fromName: "", fromEmail: sender, toList: "", ccList: "",
                            date: Date(), snippet: "", bodyHTML: nil, bodyText: nil,
                            isUnread: false, messageIdHeader: "", referencesHeader: "",
                            listUnsubscribe: "", listUnsubscribePost: "", isDraft: false).insert(db)
            }
            try BlockRule(pattern: "spam@foo.com", kind: "email").insert(db)
            try BlockRule(pattern: "bar.com", kind: "domain").insert(db)
        }

        let blocked = try await db.writer.read { db in try MailboxFilter.blocked.fetch(db) }
        XCTAssertEqual(Set(blocked.map(\.id)), ["t1", "t2"])
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

    /// A draft that was sent (and so removed from its Gmail thread) must not
    /// survive locally — otherwise it keeps rendering with a DRAFT badge.
    func testStorePrunesMessagesMissingFromServerThread() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            try Account(id: "acc1", email: "me@example.com").insert(db)
        }
        let engine = SyncEngine(db: db, tokens: TokenManager(
            config: GoogleOAuthConfig(clientID: "x.apps.googleusercontent.com")))

        func gThread(messageIds: [String]) throws -> GThread {
            let messages = messageIds.map { id in
                """
                {"id":"\(id)","threadId":"t1","labelIds":["INBOX"],"snippet":"s",
                 "internalDate":"1700000000000",
                 "payload":{"partId":"","mimeType":"text/plain",
                            "headers":[{"name":"From","value":"a@example.com"},
                                       {"name":"Subject","value":"hello"}],
                            "body":{"size":0}}}
                """
            }.joined(separator: ",")
            let json = "{\"id\":\"t1\",\"messages\":[\(messages)]}"
            return try JSONDecoder().decode(GThread.self, from: Data(json.utf8))
        }

        try await engine.store(gThread: gThread(messageIds: ["m1", "draft1"]), accountId: "acc1")
        var ids = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM message WHERE accountId='acc1' ORDER BY id")
        }
        XCTAssertEqual(ids, ["draft1", "m1"])

        // Server thread no longer carries the draft — it must vanish locally.
        try await engine.store(gThread: gThread(messageIds: ["m1", "m2"]), accountId: "acc1")
        ids = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM message WHERE accountId='acc1' ORDER BY id")
        }
        XCTAssertEqual(ids, ["m1", "m2"])

        // The index is contentless and keyed by message rowid, so its rows
        // are named by joining back through `message`.
        let ftsIds = try await db.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM message_fts
                JOIN message m ON m.rowid = message_fts.rowid
                WHERE m.accountId = 'acc1' ORDER BY m.id
                """)
        }
        XCTAssertEqual(ftsIds, ["m1", "m2"], "search index must drop the sent draft too")
    }

    /// `store` skips a thread whose fingerprint hasn't moved. The skip must
    /// never swallow a real change — a label flipping is exactly the case
    /// that would otherwise leave mail frozen in the wrong state forever.
    func testStoreSkipsUnchangedButNotChangedThreads() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            try Account(id: "acc1", email: "me@example.com").insert(db)
        }
        let engine = SyncEngine(db: db, tokens: TokenManager(
            config: GoogleOAuthConfig(clientID: "x.apps.googleusercontent.com")))

        func gThread(labels: [String], subject: String = "hello") throws -> GThread {
            let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
            let json = """
            {"id":"t1","messages":[
              {"id":"m1","threadId":"t1","labelIds":[\(labelJSON)],"snippet":"s",
               "internalDate":"1700000000000",
               "payload":{"partId":"","mimeType":"text/plain",
                          "headers":[{"name":"From","value":"a@example.com"},
                                     {"name":"Subject","value":"\(subject)"}],
                          "body":{"size":0}}}]}
            """
            return try JSONDecoder().decode(GThread.self, from: Data(json.utf8))
        }
        func stored() async throws -> MailThread? {
            try await db.writer.read { db in
                try MailThread.fetchOne(db, sql: "SELECT * FROM thread WHERE accountId='acc1' AND id='t1'")
            }
        }

        try await engine.store(gThread: gThread(labels: ["INBOX", "UNREAD"]), accountId: "acc1")
        var t = try await stored()
        XCTAssertEqual(t?.isUnread, true)

        // Same thread again: nothing to do, and nothing broken by not doing it.
        try await engine.store(gThread: gThread(labels: ["INBOX", "UNREAD"]), accountId: "acc1")
        t = try await stored()
        XCTAssertEqual(t?.isUnread, true)
        XCTAssertEqual(t?.subject, "hello")

        // Read on the server — the label change must land.
        try await engine.store(gThread: gThread(labels: ["INBOX"]), accountId: "acc1")
        t = try await stored()
        XCTAssertEqual(t?.isUnread, false, "a label change must never be skipped")

        // And a body/subject change with identical labels.
        try await engine.store(gThread: gThread(labels: ["INBOX"], subject: "edited"),
                               accountId: "acc1")
        t = try await stored()
        XCTAssertEqual(t?.subject, "edited", "a content change must never be skipped")

        let searchable = try await db.writer.read { db in
            try MailSearch.threads(db, match: MailSearch.ftsQuery("edited")!)
        }
        XCTAssertEqual(searchable.map(\.id), ["t1"], "the index must track the change too")
    }

    /// Archived = out of the inbox, but not trashed, spam, or an unsent
    /// draft — and never something still sitting in Open.
    func testArchivedMailbox() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            try Account(id: "acc1", email: "me@example.com").insert(db)
        }
        let engine = SyncEngine(db: db, tokens: TokenManager(
            config: GoogleOAuthConfig(clientID: "x.apps.googleusercontent.com")))

        func gThread(id: String, labels: [String]) throws -> GThread {
            let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
            let json: String = """
            {"id":"\(id)","messages":[
              {"id":"m_\(id)","threadId":"\(id)","labelIds":[\(labelJSON)],"snippet":"s",
               "internalDate":"1700000000000",
               "payload":{"partId":"","mimeType":"text/plain",
                          "headers":[{"name":"From","value":"a@example.com"},
                                     {"name":"Subject","value":"\(id)"}],
                          "body":{"size":0}}}]}
            """
            return try JSONDecoder().decode(GThread.self, from: Data(json.utf8))
        }

        try await engine.store(gThread: gThread(id: "inboxed", labels: ["INBOX"]), accountId: "acc1")
        try await engine.store(gThread: gThread(id: "archived", labels: ["CATEGORY_PERSONAL"]), accountId: "acc1")
        try await engine.store(gThread: gThread(id: "archivedSent", labels: ["SENT"]), accountId: "acc1")
        try await engine.store(gThread: gThread(id: "trashed", labels: ["TRASH"]), accountId: "acc1")
        try await engine.store(gThread: gThread(id: "spammed", labels: ["SPAM"]), accountId: "acc1")
        try await engine.store(gThread: gThread(id: "drafted", labels: ["DRAFT"]), accountId: "acc1")

        let ids = try await db.writer.read { db in
            try MailboxFilter.archived.fetch(db).map(\.id)
        }.sorted()
        XCTAssertEqual(ids, ["archived", "archivedSent"],
                       "archived is all-mail-minus-inbox, excluding trash/spam/drafts")

        // A thread parked in Open is still awaiting action, not archived.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE thread SET isOpen = 1 WHERE id = 'archived'")
        }
        let afterOpen = try await db.writer.read { db in
            try MailboxFilter.archived.fetch(db).map(\.id)
        }
        XCTAssertEqual(afterOpen, ["archivedSent"], "Open threads must not show as archived")
    }

    /// Sending an edited draft deletes it from Gmail, but the history feed
    /// doesn't report that — the local purge has to clear the DRAFT badge,
    /// the Drafts mailbox row, and (for a standalone draft) the thread shell.
    func testPurgeDraftClearsThreadState() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            try Account(id: "acc1", email: "me@example.com").insert(db)
        }
        let engine = SyncEngine(db: db, tokens: TokenManager(
            config: GoogleOAuthConfig(clientID: "x.apps.googleusercontent.com")))

        func gThread(id: String, messages: [(String, [String])]) throws -> GThread {
            // Explicit String: GRDB makes `SQL` expressible by string
            // interpolation, and inference picks it over String otherwise.
            let body = messages.map { (mid, labels) -> String in
                let labelJSON = labels.map { "\"\($0)\"" }.joined(separator: ",")
                return """
                {"id":"\(mid)","threadId":"\(id)","labelIds":[\(labelJSON)],"snippet":"s",
                 "internalDate":"1700000000000",
                 "payload":{"partId":"","mimeType":"text/plain",
                            "headers":[{"name":"From","value":"a@example.com"},
                                       {"name":"Subject","value":"hello"}],
                            "body":{"size":0}}}
                """
            }.joined(separator: ",")
            let json: String = "{\"id\":\"\(id)\",\"messages\":[\(body)]}"
            return try JSONDecoder().decode(GThread.self, from: Data(json.utf8))
        }

        // Reply draft: the thread survives, minus its draft.
        try await engine.store(gThread: gThread(id: "t1", messages: [
            ("m1", ["INBOX"]), ("d1", ["DRAFT"]),
        ]), accountId: "acc1")
        try await db.purgeDraft(accountId: "acc1", messageId: "d1")

        let thread = try await db.writer.read { db in
            try MailThread.fetchOne(db, sql: "SELECT * FROM thread WHERE accountId='acc1' AND id='t1'")
        }
        XCTAssertEqual(thread?.hasDraft, false, "DRAFT badge must clear")
        XCTAssertEqual(thread?.messageCount, 1)
        let labels = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT labelId FROM thread_label WHERE accountId='acc1' AND threadId='t1'")
        }
        XCTAssertFalse(labels.contains("DRAFT"), "thread must leave the Drafts mailbox")
        let remaining = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM message WHERE accountId='acc1' AND threadId='t1'")
        }
        XCTAssertEqual(remaining, ["m1"])

        // Standalone draft: nothing left, so the thread shell goes too.
        try await engine.store(gThread: gThread(id: "t2", messages: [("d2", ["DRAFT"])]),
                               accountId: "acc1")
        try await db.purgeDraft(accountId: "acc1", messageId: "d2")
        let shell = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE accountId='acc1' AND id='t2'")
        }
        XCTAssertEqual(shell, 0, "a draft-only thread must disappear once the draft is sent")
    }
}

final class MimeMixedTests: XCTestCase {
    func testFileAttachmentWrapsInMixedAndInlineInRelated() {
        let inline = ComposeAttachment(id: "img@spoon.local", filename: "a.png", mimeType: "image/png", data: Data([1]), isInline: true)
        let file = ComposeAttachment(filename: "doc.pdf", mimeType: "application/pdf", data: Data([2]), isInline: false)
        let raw = String(decoding: MimeBuilder.build(fromEmail: "a@b.c", to: "d@e.f", cc: "", bcc: "", subject: "s",
                                                      bodyText: "hi", attachments: [inline, file],
                                                      inReplyTo: "", references: ""), as: UTF8.self)
        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed; boundary=\"sdh-mix-"))
        XCTAssertTrue(raw.contains("Content-Type: multipart/related;"))
        XCTAssertTrue(raw.contains("Content-Disposition: attachment; filename=\"doc.pdf\""))
        XCTAssertTrue(raw.contains("Content-ID: <img@spoon.local>"))
        XCTAssertEqual(raw.components(separatedBy: "--sdh-mix-").count, 4) // open, related part, pdf part, close
        // File-only: no related layer at all
        let onlyFile = String(decoding: MimeBuilder.build(fromEmail: "a@b.c", to: "d@e.f", cc: "", bcc: "", subject: "s",
                                                          bodyText: "hi", attachments: [file],
                                                          inReplyTo: "", references: ""), as: UTF8.self)
        XCTAssertFalse(onlyFile.contains("multipart/related"))
        XCTAssertTrue(onlyFile.contains("multipart/mixed"))
    }
}

/// Undoes quoted-printable: `=XX` back to a byte, `=CRLF` soft breaks removed,
/// hard CRLF back to LF. Runs over a whole message; headers and boundaries
/// carry no `=XX` sequences so they pass through unchanged.
private func qpDecode(_ s: String) -> String {
    let bytes = Array(s.utf8)
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
        if bytes[i] == 61, i + 2 < bytes.count {
            if bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
            if let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v); i += 3; continue
            }
        }
        out.append(bytes[i]); i += 1
    }
    return String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
}
