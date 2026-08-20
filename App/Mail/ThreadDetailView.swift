import SwiftUI
import WebKit
import MailCore

struct ThreadDetailView: View {
    @EnvironmentObject var model: AppModel
    let thread: MailThread
    /// iOS reader hooks. `onArchive` replaces the plain archive so the
    /// reader can move on to the next thread; `nextThread` + `onPullNext`
    /// drive the pull-past-the-bottom gesture. Both nil on the Mac.
    var onArchive: (() -> Void)? = nil
    var nextThread: MailThread? = nil
    var previousThread: MailThread? = nil
    var onPullNext: (() -> Void)? = nil
    var onPullPrevious: (() -> Void)? = nil
    @StateObject private var detail = ThreadDetailModel()
    /// Signed: positive = pulling past the bottom, negative = past the top.
    @State private var pullProgress: CGFloat = 0
    /// Which way the swap slides lives on the model (`readerSlideForward`)
    /// now, so clicks in the list and j/k — which change the selection from
    /// outside this view — pick their direction too, not just the pulls.
    private var slideForward: Bool { model.readerSlideForward }

    private func archive() {
        if let onArchive { onArchive() } else { model.archive(thread) }
    }

    private func act(_ action: String) {
        switch action {
        case "reply": model.reply(to: thread, all: false)
        case "replyall": model.reply(to: thread, all: true)
        case "archive": archive()
        default: break
        }
    }

    private var canUnsubscribe: Bool {
        detail.messages.last { !$0.listUnsubscribe.isEmpty } != nil
    }

    var body: some View {
        // The ZStack is the stage: on a pull the outgoing thread slides off one
        // edge while the incoming one slides in from the other. Identity is
        // the thread key, so a swap is a removal plus an insertion.
        ZStack {
            content
                .id(thread.key)
                .transition(.asymmetric(
                    insertion: .move(edge: slideForward ? .bottom : .top),
                    removal: .move(edge: slideForward ? .top : .bottom)))
        }
        .clipped()
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

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.subject)
                        .font(CWT.font(14, bold: true))
                        .lineLimit(2)
                        .textSelection(.enabled)
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
                        archive()
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
                },
                onAction: { action in
                    act(action)
                },
                onPull: { progress in
                    if pullProgress != progress { pullProgress = progress }
                },
                onPullNext: onPullNext.map { go in {
                    model.readerSlideForward = true
                    withAnimation(CWT.nav) { go() }
                } },
                onPullPrevious: onPullPrevious.map { go in {
                    model.readerSlideForward = false
                    withAnimation(CWT.nav) { go() }
                } }
            )
            .overlay(alignment: .bottom) { pullHint(forward: true) }
            .overlay(alignment: .top) { pullHint(forward: false) }
        }
    }

    /// Rises out of the edge you're pulling past: what's next (or previous),
    /// and whether you've pulled far enough to go there.
    @ViewBuilder private func pullHint(forward: Bool) -> some View {
        let progress = forward ? pullProgress : -pullProgress
        let target = forward ? nextThread : previousThread
        let enabled = forward ? onPullNext != nil : onPullPrevious != nil
        if progress > 0, enabled {
            HStack(spacing: 6) {
                if let target {
                    Image(systemName: progress >= 1
                          ? (forward ? "arrow.down.to.line" : "arrow.up.to.line")
                          : (forward ? "arrow.down" : "arrow.up"))
                        .imageScale(.small)
                    Text(progress >= 1
                         ? (forward ? "Release for next" : "Release for previous")
                         : (forward ? "Pull for next" : "Pull for previous"))
                    Text("·").foregroundStyle(CWT.ink3)
                    Text(target.subject.isEmpty ? "(no subject)" : target.subject)
                        .lineLimit(1)
                        .foregroundStyle(CWT.ink2)
                } else {
                    Text(forward ? "No more conversations" : "Already at the first conversation")
                        .foregroundStyle(CWT.ink3)
                }
            }
            .font(CWT.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(CWT.paper)
            .overlay(alignment: forward ? .top : .bottom) { Hairline() }
            .opacity(Double(min(1, progress * 1.5)))
            .allowsHitTesting(false)
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
                var plain = "<div class='plain'>\(linkify(main))</div>"
                if let quoted {
                    plain += """
                    <details class="plainq"><summary>•••</summary>\
                    <div class='plain quoted'>\(linkify(quoted))</div></details>
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
          .plain a { color: inherit; text-decoration: underline; text-underline-offset: 2px; }
          .plain.quoted { color: var(--ink3); }
          details.plainq summary { cursor: pointer; color: var(--ink2); list-style: none;
              display: inline-block; border: 1px solid var(--hairline);
              padding: 0 8px; margin: 8px 0; font-size: 11px; }
          .frame { width: 100%; border: none; height: 120px; background: #fff; }
          ::selection { background: #b4d5fe; color: #111; }
          .actions { display: flex; gap: 8px; padding: 14px 16px 0; }
          .act { border: 1px solid var(--ink); color: var(--ink); padding: 5px 12px;
                 font-size: 11px; text-decoration: none; font-family: inherit; }
          .act.archive { margin-left: auto; }
          .act:hover { opacity: 0.55; }
        </style></head><body>\(sections)
        <div class="actions">
          <a class="act" href="sdh-action://reply">&#x21A9; Reply</a>
          <a class="act" href="sdh-action://replyall">&#x21A9;&#x21A9; Reply All</a>
          <a class="act archive" href="sdh-action://archive">Archive</a>
        </div>
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
        // Tell the native side where the page is scrolled — the Mac's
        // pull-for-next needs the edges, and the position comes back through
        // restoreScroll when a re-render reloads the page.
        function postScroll() {
          try {
            var end = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
            var start = window.scrollY <= 2;
            window.webkit.messageHandlers.sdhScroll.postMessage({
              b: (end ? 1 : 0) + (start ? 2 : 0), y: window.scrollY });
          } catch (err) {}
        }
        window.addEventListener('scroll', postScroll, { passive: true });
        window.addEventListener('load', postScroll);
        if (window.ResizeObserver) new ResizeObserver(postScroll).observe(document.body);
        // Re-renders of the open thread (a draft autosave, say) reload the
        // whole page; the native side hands back where the reader was. The
        // page grows as message iframes fit, so keep nudging until the
        // target sticks, the reader scrolls, or we give up.
        function restoreScroll(y) {
          var tries = 0, cancelled = false;
          function cancel() { cancelled = true; }
          window.addEventListener('wheel', cancel, { once: true, passive: true });
          window.addEventListener('touchstart', cancel, { once: true, passive: true });
          (function attempt() {
            if (cancelled || tries++ > 40) return;
            window.scrollTo(0, y);
            if (Math.abs(window.scrollY - y) <= 2) return;
            setTimeout(attempt, 50);
          })();
        }
        // Same idea sideways: whether anything in the page (the page itself,
        // a plain-text body, a message iframe's document) still has room to
        // scroll horizontally, per direction. The native side uses it to
        // decide if a sideways pan belongs to the email or the board strip.
        function postHScroll() {
          try {
            var l = false, r = false;
            var els = [document.scrollingElement];
            document.querySelectorAll('.plain').forEach(function (e) { els.push(e); });
            document.querySelectorAll('iframe.frame').forEach(function (f) {
              try {
                var d = f.contentDocument;
                if (d && d.scrollingElement) els.push(d.scrollingElement);
              } catch (e) {}
            });
            els.forEach(function (e) {
              if (!e) return;
              if (e.scrollLeft > 1) l = true;
              if (e.scrollLeft + e.clientWidth < e.scrollWidth - 1) r = true;
            });
            window.webkit.messageHandlers.sdhHScroll.postMessage((l ? 1 : 0) + (r ? 2 : 0));
          } catch (err) {}
        }
        window.addEventListener('scroll', postHScroll, { passive: true, capture: true });
        window.addEventListener('load', postHScroll);
        if (window.ResizeObserver) new ResizeObserver(postHScroll).observe(document.body);
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
        // Bare URLs and addresses in an HTML email that the sender didn't
        // link: wrap them in anchors. Text nodes only, never inside an
        // existing link or anything that isn't prose.
        var URL_RE = /(https?:\\/\\/[^\\s<>"']+|www\\.[^\\s<>"']+|[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+)/g;
        function linkifyDoc(d) {
          try {
            if (!d.body) return;
            var walker = d.createTreeWalker(d.body, NodeFilter.SHOW_TEXT, {
              acceptNode: function (n) {
                if (!n.nodeValue || !/[:@.]/.test(n.nodeValue)) return NodeFilter.FILTER_REJECT;
                var p = n.parentElement;
                while (p) {
                  var t = p.tagName;
                  if (t === 'A' || t === 'SCRIPT' || t === 'STYLE' || t === 'TEXTAREA' ||
                      t === 'BUTTON' || t === 'TITLE') return NodeFilter.FILTER_REJECT;
                  p = p.parentElement;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            var nodes = [];
            while (walker.nextNode()) nodes.push(walker.currentNode);
            nodes.forEach(function (n) {
              var text = n.nodeValue;
              URL_RE.lastIndex = 0;
              if (!URL_RE.test(text)) return;
              URL_RE.lastIndex = 0;
              var frag = d.createDocumentFragment(), last = 0, m;
              while ((m = URL_RE.exec(text))) {
                var raw = m[0], trail = '';
                // Don't take trailing punctuation along for the ride.
                while (/[.,;:)\\]}'"]$/.test(raw)) { trail = raw.slice(-1) + trail; raw = raw.slice(0, -1); }
                if (m.index > last) frag.appendChild(d.createTextNode(text.slice(last, m.index)));
                var a = d.createElement('a');
                a.href = raw.indexOf('@') > -1 && raw.indexOf('://') === -1 ? 'mailto:' + raw
                       : raw.indexOf('://') === -1 ? 'https://' + raw : raw;
                a.textContent = raw;
                frag.appendChild(a);
                if (trail) frag.appendChild(d.createTextNode(trail));
                last = m.index + m[0].length;
              }
              if (last < text.length) frag.appendChild(d.createTextNode(text.slice(last)));
              n.parentNode.replaceChild(frag, n);
            });
          } catch (err) {}
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
              linkifyDoc(d);
              collapseQuotes(f, d);
              d.addEventListener('click', function (e) {
                if (e.target.tagName === 'BUTTON') return;
                var a = e.target.closest ? e.target.closest('a') : null;
                if (a && a.href) { e.preventDefault(); e.stopPropagation(); openExternal(a.href); }
              }, true);
              watch(f, d);
              // Iframe-internal scrolls never reach the parent window; report
              // horizontal edges from in here too.
              d.addEventListener('scroll', postHScroll, { passive: true, capture: true });
              postHScroll();
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

    /// Escapes plain text and turns bare URLs / addresses into links.
    /// Runs on the escaped text so the anchors survive escaping and nothing
    /// in the body can smuggle markup in around them.
    static func linkify(_ s: String) -> String {
        let text = escape(s)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return text }
        let ns = text as NSString
        var out = ""
        var pos = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url else { continue }
            var range = match.range
            // The detector happily takes trailing punctuation along; trim it.
            while range.length > 0,
                  ".,;:)]}'".contains(ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))) {
                range.length -= 1
            }
            guard range.length > 0 else { continue }
            // `shown` is already HTML-escaped (so "&amp;" inside a query string
            // decodes back to "&" in the href too); only quotes need care.
            let shown = ns.substring(with: range)
            let href: String
            if url.scheme == "mailto" || (shown.contains("@") && !shown.contains("://")) {
                href = shown.hasPrefix("mailto:") ? shown : "mailto:" + shown
            } else if shown.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil {
                href = shown
            } else {
                href = "https://" + shown
            }
            out += ns.substring(with: NSRange(location: pos, length: range.location - pos))
            out += "<a href=\"\(href.replacingOccurrences(of: "\"", with: "&quot;"))\">\(shown)</a>"
            pos = range.location + range.length
        }
        out += ns.substring(from: pos)
        return out
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
/// A web view that treats sideways trackpad pans the way the columns do:
/// they belong to the board strip — unless the email itself still has
/// horizontal room that way (a wide table, a plain-text body), in which case
/// the email scrolls first and the strip takes over on the next gesture past
/// the edge. Each gesture's route is latched when it begins — vertical (and
/// diagonal-but-mostly-vertical) scrolling stays in the message, horizontal
/// goes up the responder chain to the enclosing horizontal scroller,
/// momentum included.
final class PanThroughWebView: WKWebView {
    /// Whether the page reports horizontal room of its own, per direction
    /// (kept current by the page's sdhHScroll messages).
    var contentCanPanLeft = false
    var contentCanPanRight = false
    private var panningStrip = false

    override func scrollWheel(with event: NSEvent) {
        // A new trackpad gesture — or a lone legacy-wheel tick — picks its
        // route; momentum events keep whatever the gesture latched.
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            // Positive deltaX pans toward content on the left.
            let contentTakesIt = event.scrollingDeltaX > 0 ? contentCanPanLeft : contentCanPanRight
            panningStrip = horizontal && !contentTakesIt
        }
        if panningStrip {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct MessageWebView: NSViewRepresentable {
    let html: String
    var onAttachment: ((String, String) -> Void)?
    var onEditDraft: ((String) -> Void)?
    var onDeleteDraft: ((String) -> Void)?
    var onMailto: ((String) -> Void)?
    var onAction: ((String) -> Void)?
    /// iOS-only pull-for-next hooks; accepted here so the call site is shared.
    var onPull: ((CGFloat) -> Void)?
    var onPullNext: (() -> Void)?
    var onPullPrevious: (() -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sdhOpen")
        config.userContentController.add(context.coordinator, name: "sdhScroll")
        config.userContentController.add(context.coordinator, name: "sdhHScroll")
        // Parent page JS sizes the message iframes; email content itself
        // stays script-free (iframe sandbox has no allow-scripts).
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = PanThroughWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.watchPull(on: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onAttachment = onAttachment
        context.coordinator.onEditDraft = onEditDraft
        context.coordinator.onDeleteDraft = onDeleteDraft
        context.coordinator.onMailto = onMailto
        context.coordinator.onAction = onAction
        context.coordinator.onPull = onPull
        context.coordinator.onPullNext = onPullNext
        context.coordinator.onPullPrevious = onPullPrevious
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
    var onAction: ((String) -> Void)?
    var onPull: ((CGFloat) -> Void)?
    var onPullNext: (() -> Void)?
    var onPullPrevious: (() -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sdhOpen")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = PanThroughWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        // Short threads still need to rubber-band, or there's nothing to pull.
        view.scrollView.alwaysBounceVertical = true
        // Watch the offset rather than the scroll view's delegate (WebKit
        // owns that) or its pan gesture (which never reported to us).
        context.coordinator.watchPull(on: view.scrollView)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onAttachment = onAttachment
        context.coordinator.onEditDraft = onEditDraft
        context.coordinator.onDeleteDraft = onDeleteDraft
        context.coordinator.onMailto = onMailto
        context.coordinator.onAction = onAction
        context.coordinator.onPull = onPull
        context.coordinator.onPullNext = onPullNext
        context.coordinator.onPullPrevious = onPullPrevious
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
    /// Where the reader is, per the page's scroll reports, and where to put
    /// them back after a same-thread re-render — a draft autosave, a
    /// read-state change — reloads the page out from under them.
    private var lastScrollY: Double = 0
    private var restoreScrollY: Double?

    func needsLoad(_ html: String) -> Bool { pendingHTML != html }

    func load(_ html: String, into view: WKWebView) {
        webView = view
        // A new thread gets a fresh coordinator, so a reload over a finished
        // page is the same thread re-rendered — keep the reader's place.
        if loadedHTML != nil {
            #if os(macOS)
            restoreScrollY = lastScrollY
            #else
            restoreScrollY = Double(view.scrollView.contentOffset.y)
            #endif
        }
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
        if let y = restoreScrollY {
            restoreScrollY = nil
            if y > 1 { webView.evaluateJavaScript("restoreScroll(\(Int(y)))") }
        }
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
    var onAction: ((String) -> Void)?
    var onPull: ((CGFloat) -> Void)?
    var onPullNext: (() -> Void)?
    var onPullPrevious: (() -> Void)?

    /// How far past the end of the page the finger has to drag before
    /// letting go moves on to the next conversation.
    private static let pullDistance: CGFloat = 80
    private var pullArmed = false
    private var pullProgress: CGFloat = 0
    /// The page reports whether it's scrolled to its end / start (sdhScroll).
    private var atEnd = false
    private var atStart = false

    #if os(macOS)
    private var scrollMonitor: Any?
    private var pulledDistance: CGFloat = 0

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    /// Trackpad pull past the end of the thread → next. WKWebView on the Mac
    /// hides its scroll view, so listen to the scroll-wheel gesture directly:
    /// finger-driven phases only (no momentum), counting only while the page
    /// says it's at its end, committing when the fingers lift.
    func watchPull(on view: WKWebView) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
            guard let self, let view, event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            else { return event }
            switch event.phase {
            case .began:
                pulledDistance = 0
                pullArmed = false
            case .changed:
                guard event.momentumPhase == [] else { break }
                // Negative scrollingDeltaY = content moving up = pulling the
                // bottom; positive = pulling the top. Only counts while the
                // page is already at that edge.
                let d = -event.scrollingDeltaY
                if d < 0 && atStart {
                    pulledDistance = min(0, pulledDistance + d)
                } else if d > 0 && atEnd {
                    pulledDistance = max(0, pulledDistance + d)
                } else if (d < 0 && !atStart) || (d > 0 && !atEnd) {
                    pulledDistance = 0
                }
                let progress = max(-1, min(1, pulledDistance / (Self.pullDistance * 2)))
                pullArmed = abs(progress) >= 1
                report(progress)
            case .ended, .cancelled:
                let fire = pullArmed && event.phase == .ended
                let forward = pulledDistance > 0
                pullArmed = false
                pulledDistance = 0
                report(0)
                if fire { forward ? onPullNext?() : onPullPrevious?() }
            default:
                break
            }
            return event
        }
    }
    #endif

    #if os(iOS)

    private var offsetObservation: NSKeyValueObservation?
    private var pullForward = true

    func watchPull(on scrollView: UIScrollView) {
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
            self?.scrolled(sv)
        }
    }

    /// Pull-past-the-bottom → next thread. The overscroll is read off the
    /// scroll view while the finger is down; the finger lifting is what
    /// commits (the bounce-back is what brings us here with isTracking off).
    private func scrolled(_ sv: UIScrollView) {
        let minOffset = -sv.adjustedContentInset.top
        let maxOffset = max(minOffset,
                            sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height)
        // Signed overscroll: past the bottom is positive, past the top negative.
        let over: CGFloat
        if sv.contentOffset.y > maxOffset { over = sv.contentOffset.y - maxOffset }
        else if sv.contentOffset.y < minOffset { over = sv.contentOffset.y - minOffset }
        else { over = 0 }
        if sv.isTracking {
            let progress = max(-1, min(1, over / Self.pullDistance))
            let armed = abs(progress) >= 1
            if armed != pullArmed {
                pullArmed = armed
                if armed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
            pullForward = progress > 0
            report(progress)
        } else {
            let fire = pullArmed
            pullArmed = false
            report(0)
            if fire { pullForward ? onPullNext?() : onPullPrevious?() }
        }
    }

    #endif

    private func report(_ progress: CGFloat) {
        // Throttle: the parent view re-renders on every change.
        guard abs(progress - pullProgress) > 0.03 || progress == 0 || progress == 1 else { return }
        pullProgress = progress
        onPull?(progress)
    }

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
        if message.name == "sdhScroll" {
            let body = message.body as? [String: Any]
            let bits = (body?["b"] as? Int) ?? 0
            atEnd = bits & 1 != 0
            atStart = bits & 2 != 0
            lastScrollY = (body?["y"] as? Double) ?? lastScrollY
            return
        }
        #if os(macOS)
        if message.name == "sdhHScroll" {
            let bits = (message.body as? Int) ?? 0
            if let view = message.webView as? PanThroughWebView {
                view.contentCanPanLeft = bits & 1 != 0
                view.contentCanPanRight = bits & 2 != 0
            }
            return
        }
        #endif
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
        // Footer buttons: sdh-action://reply | replyall | archive
        if url.scheme == "sdh-action" {
            if let action = url.host { onAction?(action) }
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
