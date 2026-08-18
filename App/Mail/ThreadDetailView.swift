import SwiftUI
import WebKit
import MailCore

struct ThreadDetailView: View {
    @EnvironmentObject var model: AppModel
    let thread: MailThread
    @StateObject private var detail = ThreadDetailModel()

    private var canUnsubscribe: Bool {
        detail.messages.last { !$0.listUnsubscribe.isEmpty } != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.subject)
                        .font(CWT.font(14, bold: true))
                        .lineLimit(2)
                    Text(model.accountEmail(thread.accountId))
                        .font(CWT.caption)
                        .foregroundStyle(CWT.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button {
                        model.reply(to: thread, all: false)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .help("Reply (R)")
                    Button {
                        model.reply(to: thread, all: true)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left.2")
                    }
                    .help("Reply All (A)")
                    Button {
                        model.forward(thread)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                    }
                    .help("Forward (F)")
                    Button {
                        model.toggleOpen(thread)
                    } label: {
                        Image(systemName: thread.isOpen ? "clock.fill" : "clock")
                    }
                    .help(thread.isOpen ? "Remove from Open (O)" : "Mark Open (O) — awaiting reply / act later")
                    Button {
                        model.toggleStar(thread)
                    } label: {
                        Image(systemName: thread.isStarred ? "star.fill" : "star")
                            .foregroundStyle(thread.isStarred ? CWT.orange : CWT.ink)
                    }
                    .help("Star (S)")
                    Button {
                        model.markRead(thread, read: false)
                    } label: {
                        Image(systemName: "envelope.badge")
                    }
                    .help("Mark Unread (U)")
                    Button {
                        model.archive(thread)
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .help("Archive (E)")
                    Button {
                        model.beginUnsubscribe(thread)
                    } label: {
                        Image(systemName: "envelope.arrow.triangle.branch")
                    }
                    .disabled(!canUnsubscribe)
                    .help(canUnsubscribe
                          ? "Unsubscribe from this sender"
                          : "No unsubscribe link in this message")
                    Menu {
                        Button("Block Sender", role: .destructive) { model.block(thread, wholeDomain: false) }
                        Button("Block Domain", role: .destructive) { model.block(thread, wholeDomain: true) }
                        Divider()
                        Button("Manage Blocked…") { model.showBlocked = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("More… (⌘K opens the command palette)")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(CWT.paper)
            Hairline()
            MessageWebView(
                html: detail.html,
                onAttachment: { messageId, partId in
                    if let att = detail.attachments[messageId]?.first(where: { $0.partId == partId }) {
                        model.download(att)
                    }
                },
                onEditDraft: { messageId in
                    model.editDraft(messageId: messageId, in: thread)
                },
                onDeleteDraft: { messageId in
                    model.deleteDraft(messageId: messageId, in: thread)
                },
                onMailto: { address in
                    model.compose(to: address)
                }
            )
        }
        .onAppear {
            detail.observe(db: model.db, accounts: model.accountStore, thread: thread)
            if thread.isUnread {
                model.markRead(thread, read: true, recordUndo: false)
            }
        }
        .onChange(of: thread.key) {
            detail.observe(db: model.db, accounts: model.accountStore, thread: thread)
            if thread.isUnread {
                model.markRead(thread, read: true, recordUndo: false)
            }
        }
    }
}

enum ThreadHTML {
    /// Each HTML message renders in its own sandboxed iframe so email
    /// stylesheets can't bleed into each other or the chrome. Messages run
    /// newest → oldest: the message you opened the thread for is right there
    /// at the top, with no scrolling and no waiting for every frame to size
    /// itself first. All are fully shown; only the quoted trail of earlier
    /// replies inside each message is folded behind "•••" (headers still
    /// toggle a message closed by hand).
    /// `inlineImages` maps a message id to its resolved `cid:` references
    /// (lowercased content id → `data:` URI). Anything not in there renders
    /// with the original `cid:` src, which a web view can't load — the frame
    /// just shows a broken image, same as before the bytes arrive.
    /// `avatars` maps a lowercased sender address to a `data:` URI. A sender
    /// missing from it draws the initials mark instead — same fallback the
    /// thread list uses, same color for the same address.
    static func render(messages allMessages: [Message],
                       attachments: [String: [Attachment]],
                       inlineImages: [String: [String: String]] = [:],
                       avatars: [String: String] = [:]) -> String {
        let messages = Array(allMessages.reversed())
        // Explicit String types everywhere: GRDB (visible through MailCore)
        // offers joined(separator:) on its SQL type and inference once
        // picked it here, turning the page into an SQL debug dump.
        let sections: String = messages.map { (m: Message) -> String in
            let body: String
            if let raw = m.bodyHTML, !raw.isEmpty {
                let html = resolveCIDs(raw, using: inlineImages[m.id] ?? [:])
                // allow-popups so target="_blank" links (most newsletters) turn
                // into a popup request the UI delegate can hand to the browser;
                // without it the sandbox swallows the click silently.
                body = "<iframe class=\"frame\" sandbox=\"allow-same-origin allow-popups\" srcdoc=\"\(escapeAttr(frameDoc(html)))\"></iframe>"
            } else if (m.bodyText ?? "").isEmpty {
                // Neither body part came down (a handful of messages, usually
                // attachment-only or an oddly encoded MIME tree). Show the
                // snippet rather than an empty pane that reads as "broken".
                body = m.snippet.isEmpty
                    ? "<div class='plain quoted'>(no message body)</div>"
                    : "<div class='plain quoted'>\(escape(m.snippet))</div>"
            } else {
                let (main, quoted) = MimeParser.splitQuoted(m.bodyText ?? "")
                var plain = "<div class='plain'>\(escape(main))</div>"
                if let quoted {
                    plain += """
                    <details class="plainq"><summary>•••</summary>\
                    <div class='plain quoted'>\(escape(quoted))</div></details>
                    """
                }
                body = plain
            }
            // A picture the body already shows isn't a separate download —
            // listing it as a chip too just doubles it up.
            let shownInline = citedIds(in: m.bodyHTML ?? "")
            let chips: String = (attachments[m.id] ?? []).filter { (a: Attachment) -> Bool in
                a.contentId.isEmpty || !shownInline.contains(a.contentId.lowercased())
            }.map { (a: Attachment) -> String in
                let size = ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)
                return """
                <a class="chip" href="sdh-attach://att/\(a.messageId)/\(a.partId)">📎 \(escape(a.filename)) <span class="chipsize">\(size)</span></a>
                """
            }.joined(separator: " ")
            let draftBadge = m.isDraft
                ? "<span class=\"badge\">DRAFT</span><button class=\"editbtn\" title=\"Edit this draft\" "
                  + "onclick=\"event.stopPropagation();window.location.href='sdh-draft://edit/\(m.id)'\">Edit</button>"
                  + "<button class=\"delbtn\" title=\"Delete this draft\" "
                  + "onclick=\"event.stopPropagation();window.location.href='sdh-draft://delete/\(m.id)'\">Delete</button>"
                : ""
            let date = m.date.formatted(date: .abbreviated, time: .shortened)
            let key = m.fromEmail.lowercased()
            let avatar: String
            if let uri = avatars[key] {
                avatar = "<img class=\"ava\" src=\"\(uri)\" alt=\"\">"
            } else {
                let hue = AvatarView.hue(for: key.isEmpty ? m.fromName : key)
                avatar = """
                <span class="ava mono" style="background:hsl(\(hue),22%,52%)">\
                \(escape(AvatarView.initials(name: m.fromName, email: m.fromEmail)))</span>
                """
            }
            return """
            <section class="msg\(m.isDraft ? " draft" : "")">
              <div class="hdr" onclick="toggleMsg(this)">
                \(avatar)
                <span class="from">\(escape(m.fromName))</span>
                <span class="addr">&lt;\(escape(m.fromEmail))&gt;</span>
                \(draftBadge)
                <span class="date">\(escape(date))</span>
                <div class="to">to \(escape(m.toList))</div>
                <div class="peek">\(escape(m.snippet))</div>
              </div>
              <div class="mbody">
                \(chips.isEmpty ? "" : "<div class=\"chips\">\(chips)</div>")
                \(body)
              </div>
            </section>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
          \(fontFaces)
          /* CW&T chrome: paper + ink, Space Mono, hairlines, no rounding.
             The message bodies inside the iframes keep their own styling. */
          :root { color-scheme: light dark;
                  --paper: #ffffff; --ink: #111111; --ink2: #4a4a4a; --ink3: #8a8a8a;
                  --hairline: #e3e3e3; --red: #d11d1d; --orange: #e35a1e; }
          @media (prefers-color-scheme: dark) {
            :root { --paper: #111111; --ink: #f6f5f2; --ink2: #b0b0b0; --ink3: #7a7a7a;
                    --hairline: #2a2a2a; }
          }
          body { font: 12px "Space Mono", "JetBrains Mono", Menlo, "Courier New", monospace;
                 margin: 0; padding: 0 0 40px; background: var(--paper); color: var(--ink);
                 line-height: 1.5; }
          .msg { padding: 12px 16px; border-bottom: 1px solid var(--hairline); }
          .msg.draft .hdr { border-left: 2px solid var(--orange); padding-left: 44px; }
          .msg.draft .ava { left: 8px; }
          /* The avatar is pulled out of the flow so the address, recipients
             and peek lines all hang off the same left edge under the name. */
          .hdr { margin-bottom: 10px; cursor: pointer; position: relative;
                 padding-left: 36px; min-height: 28px; }
          .ava { position: absolute; left: 0; top: 0; width: 28px; height: 28px;
                 object-fit: cover; border: 1px solid var(--hairline); box-sizing: border-box; }
          .ava.mono { display: flex; align-items: center; justify-content: center;
                      color: #fff; font-size: 10px; font-weight: 700; }
          .from { font-weight: 700; }
          .addr, .date, .to { color: var(--ink3); font-size: 11px; }
          .date { float: right; }
          .peek { display: none; color: var(--ink2); font-size: 11px; margin-top: 2px;
                  white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .msg.collapsed .mbody { display: none; }
          .msg.collapsed .peek { display: block; }
          .msg.collapsed .to { display: none; }
          .badge { background: var(--orange); color: #fff; font-size: 9px; font-weight: 700;
                   letter-spacing: 0.04em; padding: 1px 4px; margin-left: 6px; vertical-align: middle; }
          .editbtn, .delbtn { margin-left: 6px; padding: 1px 8px; font-size: 11px; cursor: pointer;
                     font-family: inherit; background: transparent; vertical-align: middle;
                     border-radius: 0; }
          .editbtn { border: 1px solid var(--ink); color: var(--ink); }
          .delbtn { border: 1px solid var(--red); color: var(--red); }
          .editbtn:hover, .delbtn:hover, .hdr:hover .from, .chip:hover,
          details.plainq summary:hover { opacity: 0.55; }
          .chips { margin-bottom: 8px; }
          .chip { display: inline-block; border: 1px solid var(--hairline);
                  padding: 3px 8px; margin: 0 6px 6px 0; font-size: 11px;
                  text-decoration: none; color: inherit; }
          .chipsize { color: var(--ink3); }
          .plain { white-space: pre-wrap; overflow-x: auto; }
          .plain.quoted { color: var(--ink3); }
          details.plainq summary { cursor: pointer; color: var(--ink2); list-style: none;
              display: inline-block; border: 1px solid var(--hairline);
              padding: 0 8px; margin: 8px 0; font-size: 11px; }
          .frame { width: 100%; border: none; height: 120px; background: #fff; }
          ::selection { background: #b4d5fe; color: #111; }
        </style></head><body>\(sections)
        <script>
        // Links leave the app: hand them to the native side, which opens the
        // default browser. Navigating this window is the fallback — it lands in
        // the navigation delegate, which does the same thing.
        function openExternal(href) {
          try {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.sdhOpen) {
              window.webkit.messageHandlers.sdhOpen.postMessage(href);
              return;
            }
          } catch (err) {}
          window.location.href = href;
        }
        function toggleMsg(hdr) {
          hdr.parentElement.classList.toggle('collapsed');
          setTimeout(fitAll, 0);
        }
        // Where does the quoted trail of previous replies start in this email?
        function findQuoteStart(d) {
          var el = d.querySelector('.gmail_quote, blockquote[type="cite"], .yahoo_quoted, ' +
                                   '#divRplyFwdMsg, #appendonsend, .moz-cite-prefix');
          if (el) return el;
          // Fallback: a bare attribution line like "On <date>, <sender> wrote:"
          var blocks = d.body ? d.body.querySelectorAll('div,p') : [];
          for (var i = 0; i < blocks.length; i++) {
            var t = (blocks[i].textContent || '').trim();
            if (t.length < 200 && /^On\\s/.test(t) && /wrote:$/.test(t)) return blocks[i];
          }
          return null;
        }
        function collapseQuotes(f, d) {
          var first = findQuoteStart(d);
          if (!first) return;
          // The trail runs from the marker to the end of the message, but not
          // always nested inside it (Outlook puts it in following siblings) —
          // so hide the marker plus everything after it in document order.
          var els = [first];
          var sib = first.nextElementSibling;
          while (sib) { els.push(sib); sib = sib.nextElementSibling; }
          var anc = first.parentElement;
          while (anc && d.body && anc !== d.body) {
            var s = anc.nextElementSibling;
            while (s) { els.push(s); s = s.nextElementSibling; }
            anc = anc.parentElement;
          }
          var btn = d.createElement('button');
          btn.textContent = '•••';
          btn.title = 'Show / hide quoted text';
          btn.style.cssText = 'margin:8px 0;padding:1px 8px;border:1px solid #e3e3e3;border-radius:0;background:transparent;cursor:pointer;font-size:12px;color:#8a8a8a;font-family:inherit';
          first.parentNode.insertBefore(btn, first);
          els.forEach(function (el) { el.style.display = 'none'; });
          btn.addEventListener('click', function (ev) {
            ev.preventDefault(); ev.stopPropagation();
            var hidden = first.style.display === 'none';
            els.forEach(function (el) { el.style.display = hidden ? '' : 'none'; });
            setTimeout(fitAll, 0);
          });
        }
        // Measure the CONTENT, not the frame. `documentElement.scrollHeight`
        // is clamped to the iframe's viewport, so once the frame has been
        // sized it just reports its own height back — re-measuring then adds
        // the padding again and again, and the message grows a band of
        // whitespace on every pass. `body` is height:auto, so it tracks the
        // content no matter how tall the frame already is.
        function contentHeight(d) {
          var b = d.body;
          if (!b) return 0;
          var cs = d.defaultView ? d.defaultView.getComputedStyle(b) : null;
          var m = cs ? (parseFloat(cs.marginTop) || 0) + (parseFloat(cs.marginBottom) || 0) : 0;
          // +2 absorbs sub-pixel rounding so the frame never lands a hair
          // short and grows its own inner scrollbar. Safe to add now that the
          // measurement no longer reads back the frame's height.
          return Math.ceil(b.scrollHeight + m) + 2;
        }
        // React the moment the content actually changes size, instead of
        // guessing with a ladder of timeouts.
        function watch(f, d) {
          try {
            if (!f.__ro && window.ResizeObserver) {
              f.__ro = new ResizeObserver(function () { fit(f); });
              f.__ro.observe(d.body);
            }
          } catch (e) {}
          var imgs = d.images || [];
          for (var i = 0; i < imgs.length; i++) {
            if (!imgs[i].complete) {
              imgs[i].addEventListener('load', function () { fit(f); });
              imgs[i].addEventListener('error', function () { fit(f); });
            }
          }
        }
        function fit(f) {
          try {
            var d = f.contentDocument;
            if (!d || !d.documentElement) return;
            // Hook only once REAL content is in: at t=0 the iframe still holds
            // its initial blank document, and hooking that would mark the frame
            // done before the srcdoc email ever loads.
            var hasContent = d.body &&
              (d.body.childElementCount > 0 || (d.body.textContent || '').trim().length > 0);
            // Track the document we hooked, not a boolean: a srcdoc frame
            // swaps its initial blank document for the real one, and a flag
            // leaves the listeners stranded on the document that went away.
            if (f.__hookedDoc !== d && hasContent) {
              f.__hookedDoc = d;
              f.dataset.hooked = '1';
              collapseQuotes(f, d);
              d.addEventListener('click', function (e) {
                if (e.target.tagName === 'BUTTON') return;
                var a = e.target.closest ? e.target.closest('a') : null;
                if (a && a.href) { e.preventDefault(); e.stopPropagation(); openExternal(a.href); }
              }, true);
              watch(f, d);
            }
            var section = f.closest('section');
            if (section && section.classList.contains('collapsed')) return;
            var h = Math.min(contentHeight(d), 20000);
            // Only write on a real change: an unconditional write relayouts
            // every message on every pass, and would let a 1px rounding
            // wobble feed the ResizeObserver back into itself.
            if (h > 0 && Math.abs((f.__lastH || 0) - h) > 1) {
              f.__lastH = h;
              f.style.height = h + 'px';
            }
          } catch (err) {}
        }
        function fitAll() { document.querySelectorAll('iframe.frame').forEach(fit); }
        // Newest message renders first, so the thread opens where it should
        // with no scrolling at all — nothing to pin, nothing to wait for.
        // Hook + fit as soon as each srcdoc document is actually loaded…
        document.querySelectorAll('iframe.frame').forEach(function (f) {
          f.addEventListener('load', function () { fit(f); });
        });
        // …with a short safety net for frames whose load event we missed.
        // The ResizeObserver installed in watch() handles everything after
        // that, including remote images streaming in, so this no longer has
        // to poll for seconds.
        [0, 400].forEach(function (t) { setTimeout(fitAll, t); });
        </script>
        </body></html>
        """
    }

    /// Wraps one email's HTML with sane defaults; emails render on white
    /// like they were designed for, regardless of app theme.
    private static func frameDoc(_ html: String) -> String {
        """
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
        <style>
          /* The doctype above matters: without one the frame is in quirks
             mode, where `height:100%` on anything in <body> resolves against
             the viewport — the frame — even with body at height:auto, and
             the frame and its content grow each other forever. The email's
             own doctype can't do this job because it lands after this
             <style> and is ignored. XHTML Transitional (almost-standards,
             what most email is authored against) rather than <!DOCTYPE html>
             so sliced-image tables keep their no-gap layout.
             height:auto keeps the measurement content-driven. A newsletter
             that sets html/body to 100% would otherwise stretch to whatever
             the frame currently is, and sizing the frame from that grows it
             without bound. */
          html, body { height: auto !important; min-height: 0 !important; }
          body { margin: 8px; font: 13px -apple-system, sans-serif; background: #fff; color: #000; }
          img { max-width: 100% !important; height: auto !important; }
          blockquote { border-left: 2px solid #ccc; margin: 8px 0; padding-left: 10px; color: #555; }
          /* Explicit selection color: WebKit otherwise derives it from the
             app accent, which is near-white in dark mode — invisible on the
             white email background while the window is active. */
          ::selection { background: #b4d5fe !important; color: #000 !important; }
        </style>
        \(pinViewportUnits(html))
        <style>
          /* Repeated AFTER the email on purpose. Plenty of templates ship
             `html,body{height:100%!important}`; at equal specificity and
             importance the later rule wins, and the email's <style> comes
             after the one above. Last word goes here. */
          html, body { height: auto !important; min-height: 0 !important; max-height: none !important; }
        </style>
        """
    }

    /// `100vh` and friends resolve against the iframe, and the iframe is sized
    /// to its content — so a hero block set to a viewport height grows the
    /// frame, which grows the block, forever. Real clients render into a
    /// fixed viewport; pin the units to one (600px tall) so they behave.
    private static let viewportHeightUnit = try? NSRegularExpression(
        // The lookarounds keep this out of base64: an inlined image can carry
        // a run like `K434vH/`, and with a plain word boundary that read as
        // "434vh" and got rewritten to pixels — corrupting the picture.
        pattern: "(?<![\\w+/=])(\\d*\\.?\\d+)\\s*(?:vh|svh|lvh|dvh|vmax|vb)(?![\\w+/=])",
        options: [.caseInsensitive])

    /// Space Mono for the conversation chrome, inlined: the web view is its
    /// own process and can't see fonts registered with the app, and the
    /// document has no base URL to load them from.
    static let fontFaces: String = {
        [("SpaceMono-Regular", 400), ("SpaceMono-Bold", 700)].compactMap { name, weight in
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return "@font-face { font-family: \"Space Mono\"; font-weight: \(weight); font-style: normal; "
                + "src: url(data:font/ttf;base64,\(data.base64EncodedString())) format(\"truetype\"); }"
        }.joined(separator: "\n")
    }()

    static func pinViewportUnits(_ html: String) -> String {
        guard let viewportHeightUnit else { return html }
        let ns = html as NSString
        var out = ""
        var cursor = 0
        for m in viewportHeightUnit.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let v = Double(ns.substring(with: m.range(at: 1))) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += String(format: "%.0fpx", v * 6)
            cursor = m.range.location + m.range.length
        }
        guard cursor > 0 else { return html }
        out += ns.substring(from: cursor)
        return out
    }

    /// Every `cid:` reference in a body, lowercased and percent-decoded, so
    /// they can be matched against `attachment.contentId`. Deliberately not
    /// limited to `<img>`: bodies also cite content ids from CSS backgrounds
    /// and `<v:image>` (Outlook).
    private static let cidRef = try? NSRegularExpression(
        pattern: "cid:([^\"'>\\s)]+)", options: [.caseInsensitive])

    static func citedIds(in html: String) -> Set<String> {
        guard html.contains("cid:"), let cidRef else { return [] }
        let ns = html as NSString
        var out: Set<String> = []
        for m in cidRef.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out.insert(normalizeCID(ns.substring(with: m.range(at: 1))))
        }
        return out
    }

    /// Rewrites the resolvable `cid:` references to the `data:` URIs their
    /// bytes were turned into. Web views have no way to fetch a `cid:` URL —
    /// the part lives in the message, not on the network — so the bytes have
    /// to travel inside the document.
    static func resolveCIDs(_ html: String, using map: [String: String]) -> String {
        guard !map.isEmpty, html.contains("cid:"), let cidRef else { return html }
        let ns = html as NSString
        var out = ""
        var cursor = 0
        for m in cidRef.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let uri = map[normalizeCID(ns.substring(with: m.range(at: 1)))] else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += uri
            cursor = m.range.location + m.range.length
        }
        guard cursor > 0 else { return html }
        out += ns.substring(from: cursor)
        return out
    }

    /// Content ids travel with angle brackets in the header and without them
    /// in the body, and a few senders percent-encode the `@`.
    static func normalizeCID(_ raw: String) -> String {
        (raw.removingPercentEncoding ?? raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .lowercased()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - WKWebView wrapper (email JS sandboxed, links open externally)

#if os(macOS)
struct MessageWebView: NSViewRepresentable {
    let html: String
    var onAttachment: ((String, String) -> Void)?
    var onEditDraft: ((String) -> Void)?
    var onDeleteDraft: ((String) -> Void)?
    var onMailto: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sdhOpen")
        // Parent page JS sizes the message iframes; email content itself
        // stays script-free (iframe sandbox has no allow-scripts).
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onAttachment = onAttachment
        context.coordinator.onEditDraft = onEditDraft
        context.coordinator.onDeleteDraft = onDeleteDraft
        context.coordinator.onMailto = onMailto
        if context.coordinator.needsLoad(html) {
            context.coordinator.load(html, into: view)
        }
    }

    func makeCoordinator() -> WebCoordinator { WebCoordinator() }
}
#else
struct MessageWebView: UIViewRepresentable {
    let html: String
    var onAttachment: ((String, String) -> Void)?
    var onEditDraft: ((String) -> Void)?
    var onDeleteDraft: ((String) -> Void)?
    var onMailto: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sdhOpen")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onAttachment = onAttachment
        context.coordinator.onEditDraft = onEditDraft
        context.coordinator.onDeleteDraft = onDeleteDraft
        context.coordinator.onMailto = onMailto
        if context.coordinator.needsLoad(html) {
            context.coordinator.load(html, into: view)
        }
    }

    func makeCoordinator() -> WebCoordinator { WebCoordinator() }
}
#endif

final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// What the view is supposed to be showing, and whether that load ever
    /// finished. A load can be thrown away underneath us — rapid j/k through
    /// the list cancels the previous navigation, and a heavy email can take
    /// the web content process down with it — and both leave a blank pane. A
    /// plain "did the HTML change?" check thinks the page is already up and
    /// never retries, so track the finish and reload when it doesn't come.
    private var pendingHTML: String?
    private var loadedHTML: String?
    private var retriedHTML: String?
    private weak var webView: WKWebView?

    func needsLoad(_ html: String) -> Bool { pendingHTML != html }

    func load(_ html: String, into view: WKWebView) {
        webView = view
        pendingHTML = html
        loadedHTML = nil
        retriedHTML = nil
        view.loadHTMLString(html, baseURL: nil)
    }

    /// One retry per page. The delay lets a newer load — the usual reason a
    /// navigation gets cancelled — commit first, and `isLoading` then rules
    /// the retry out entirely.
    private func reloadIfBlank(after delay: TimeInterval) {
        let html = pendingHTML
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let html, let view = self.webView,
                  self.pendingHTML == html, self.loadedHTML != html,
                  self.retriedHTML != html, !view.isLoading else { return }
            self.retriedHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedHTML = pendingHTML
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        reloadIfBlank(after: 0.3)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reloadIfBlank(after: 0.3)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadIfBlank(after: 0)
    }

    var onAttachment: ((String, String) -> Void)?
    var onEditDraft: ((String) -> Void)?
    var onDeleteDraft: ((String) -> Void)?
    var onMailto: ((String) -> Void)?

    /// Opens a link outside the app: mail addresses go to our own composer,
    /// everything else to the default browser in its own window.
    @MainActor
    func open(_ url: URL) {
        if url.scheme?.lowercased() == "mailto" {
            let address = url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
                .components(separatedBy: "?")[0]
                .removingPercentEncoding ?? ""
            if !address.isEmpty {
                onMailto?(address)
                return
            }
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// The page's click forwarder posts every link here.
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "sdhOpen",
              let href = message.body as? String,
              let url = URL(string: href) else { return }
        MainActor.assumeIsolated { open(url) }
    }

    /// target="_blank" inside an email asks for a popup window; send it to the
    /// browser and never create a second web view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            MainActor.assumeIsolated { open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // Draft buttons: sdh-draft://edit/<messageId> | sdh-draft://delete/<messageId>
        if url.scheme == "sdh-draft" {
            if let messageId = url.pathComponents.filter({ $0 != "/" }).first {
                switch url.host {
                case "edit": onEditDraft?(messageId)
                case "delete": onDeleteDraft?(messageId)
                default: break
                }
            }
            decisionHandler(.cancel)
            return
        }
        // Attachment chip: sdh-attach://att/<messageId>/<partId>
        if url.scheme == "sdh-attach" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 {
                onAttachment?(parts[0], parts[1])
            }
            decisionHandler(.cancel)
            return
        }
        // Any http(s)/mailto navigation — a link click inside an email frame,
        // or the click-forwarder's fallback — leaves the app instead of
        // loading here. about:blank/srcdoc loads are the frames themselves.
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            MainActor.assumeIsolated { open(url) }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
