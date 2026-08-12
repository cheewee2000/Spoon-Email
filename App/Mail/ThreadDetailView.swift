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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.subject)
                        .font(.headline)
                        .lineLimit(2)
                    Text(model.accountEmail(thread.accountId))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                    model.toggleStar(thread)
                } label: {
                    Image(systemName: thread.isStarred ? "star.fill" : "star")
                }
                .help("Star")
                Button {
                    model.markRead(thread, read: false)
                } label: {
                    Image(systemName: "envelope.badge")
                }
                .help("Mark unread")
                Button {
                    model.archive(thread)
                } label: {
                    Image(systemName: "archivebox")
                }
                .help("Archive (E)")
                Menu {
                    Button("Unsubscribe") { model.unsubscribe(thread) }
                        .disabled(!canUnsubscribe)
                    Divider()
                    Button("Block Sender", role: .destructive) { model.block(thread, wholeDomain: false) }
                    Button("Block Domain", role: .destructive) { model.block(thread, wholeDomain: true) }
                    Divider()
                    Button("Manage Blocked…") { model.showBlocked = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            MessageWebView(
                html: ThreadHTML.render(messages: detail.messages,
                                        attachments: detail.attachments),
                onAttachment: { messageId, partId in
                    if let att = detail.attachments[messageId]?.first(where: { $0.partId == partId }) {
                        model.download(att)
                    }
                }
            )
        }
        .onAppear {
            detail.observe(db: model.db, thread: thread)
            if thread.isUnread {
                model.markRead(thread, read: true)
            }
        }
        .onChange(of: thread.key) {
            detail.observe(db: model.db, thread: thread)
            if thread.isUnread {
                model.markRead(thread, read: true)
            }
        }
    }
}

enum ThreadHTML {
    /// Each HTML message renders in its own sandboxed iframe so email
    /// stylesheets can't bleed into each other or the chrome. Older messages
    /// start collapsed (header only); quoted trails are folded behind "•••".
    static func render(messages: [Message], attachments: [String: [Attachment]]) -> String {
        let count = messages.count
        // Explicit String types everywhere: GRDB (visible through MailCore)
        // offers joined(separator:) on its SQL type and inference once
        // picked it here, turning the page into an SQL debug dump.
        let sections: String = messages.enumerated().map { (i: Int, m: Message) -> String in
            let expanded = i == count - 1 || m.isUnread || count == 1
            let body: String
            if let html = m.bodyHTML, !html.isEmpty {
                body = "<iframe class=\"frame\" sandbox=\"allow-same-origin\" srcdoc=\"\(escapeAttr(frameDoc(html)))\"></iframe>"
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
            let chips: String = (attachments[m.id] ?? []).map { (a: Attachment) -> String in
                let size = ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)
                return """
                <a class="chip" href="sdh-attach://att/\(a.messageId)/\(a.partId)">📎 \(escape(a.filename)) <span class="chipsize">\(size)</span></a>
                """
            }.joined(separator: " ")
            let draftBadge = m.isDraft ? "<span class=\"badge\">DRAFT</span>" : ""
            let date = m.date.formatted(date: .abbreviated, time: .shortened)
            return """
            <section class="msg\(expanded ? "" : " collapsed")\(m.isDraft ? " draft" : "")">
              <div class="hdr" onclick="toggleMsg(this)">
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
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, sans-serif; margin: 0; padding: 0 0 40px; }
          .msg { padding: 12px 16px; border-bottom: 1px solid rgba(128,128,128,0.25); }
          .msg.draft .hdr { border-left: 3px solid #e5a50a; padding-left: 8px; }
          .hdr { margin-bottom: 10px; cursor: pointer; }
          .from { font-weight: 600; }
          .addr, .date, .to { color: gray; font-size: 12px; }
          .date { float: right; }
          .peek { display: none; color: gray; font-size: 12px; margin-top: 2px;
                  white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .msg.collapsed .mbody { display: none; }
          .msg.collapsed .peek { display: block; }
          .msg.collapsed .to { display: none; }
          .badge { background: #e5a50a; color: #fff; font-size: 10px; font-weight: 700;
                   border-radius: 4px; padding: 1px 5px; margin-left: 6px; vertical-align: middle; }
          .chips { margin-bottom: 8px; }
          .chip { display: inline-block; border: 1px solid rgba(128,128,128,0.4); border-radius: 12px;
                  padding: 3px 10px; margin: 0 6px 6px 0; font-size: 12px;
                  text-decoration: none; color: inherit; }
          .chipsize { color: gray; }
          .plain { white-space: pre-wrap; overflow-x: auto; }
          .plain.quoted { color: gray; }
          details.plainq summary { cursor: pointer; color: gray; list-style: none;
              display: inline-block; border: 1px solid rgba(128,128,128,0.4);
              border-radius: 10px; padding: 0 10px; margin: 8px 0; font-size: 12px; }
          .frame { width: 100%; border: none; height: 120px; background: #fff; border-radius: 4px; }
        </style></head><body>\(sections)
        <script>
        function toggleMsg(hdr) {
          hdr.parentElement.classList.toggle('collapsed');
          setTimeout(fitAll, 0);
        }
        function collapseQuotes(f, d) {
          var els = d.querySelectorAll('.gmail_quote, blockquote[type="cite"], .yahoo_quoted, #divRplyFwdMsg');
          if (!els.length) return;
          var first = els[0];
          var btn = d.createElement('button');
          btn.textContent = '•••';
          btn.style.cssText = 'margin:8px 0;padding:1px 10px;border:1px solid #ccc;border-radius:10px;background:#f5f5f5;cursor:pointer;font-size:12px;color:#555';
          first.parentNode.insertBefore(btn, first);
          els.forEach(function (el) { el.style.display = 'none'; });
          btn.addEventListener('click', function (ev) {
            ev.preventDefault(); ev.stopPropagation();
            var hidden = first.style.display === 'none';
            els.forEach(function (el) { el.style.display = hidden ? '' : 'none'; });
            setTimeout(fitAll, 0);
          });
        }
        function fit(f) {
          try {
            var d = f.contentDocument;
            if (!d || !d.documentElement) return;
            if (!f.dataset.hooked) {
              f.dataset.hooked = '1';
              collapseQuotes(f, d);
              d.addEventListener('click', function (e) {
                if (e.target.tagName === 'BUTTON') return;
                var a = e.target.closest ? e.target.closest('a') : null;
                if (a && a.href) { e.preventDefault(); window.location.href = a.href; }
              }, true);
            }
            var section = f.closest('section');
            if (section && section.classList.contains('collapsed')) return;
            f.style.height = Math.min(d.documentElement.scrollHeight + 24, 20000) + 'px';
          } catch (err) {}
        }
        function fitAll() { document.querySelectorAll('iframe.frame').forEach(fit); }
        // Re-measure a few times while remote images stream in.
        [0, 250, 600, 1200, 2500].forEach(function (t) { setTimeout(fitAll, t); });
        </script>
        </body></html>
        """
    }

    /// Wraps one email's HTML with sane defaults; emails render on white
    /// like they were designed for, regardless of app theme.
    private static func frameDoc(_ html: String) -> String {
        """
        <style>
          body { margin: 8px; font: 13px -apple-system, sans-serif; background: #fff; color: #000; }
          img { max-width: 100% !important; height: auto !important; }
          blockquote { border-left: 2px solid #ccc; margin: 8px 0; padding-left: 10px; color: #555; }
        </style>
        \(html)
        """
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

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Parent page JS sizes the message iframes; email content itself
        // stays script-free (iframe sandbox has no allow-scripts).
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onAttachment = onAttachment
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> WebCoordinator { WebCoordinator() }
}
#else
struct MessageWebView: UIViewRepresentable {
    let html: String
    var onAttachment: ((String, String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onAttachment = onAttachment
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> WebCoordinator { WebCoordinator() }
}
#endif

final class WebCoordinator: NSObject, WKNavigationDelegate {
    var lastHTML: String?
    var onAttachment: ((String, String) -> Void)?

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
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
        // Any http(s) navigation (link click or the iframe click-forwarder
        // setting window.location) opens in the system browser instead.
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
