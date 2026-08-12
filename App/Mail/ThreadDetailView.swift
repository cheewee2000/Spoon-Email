import SwiftUI
import WebKit
import MailCore

struct ThreadDetailView: View {
    @EnvironmentObject var model: AppModel
    let thread: MailThread
    @StateObject private var detail = ThreadDetailModel()

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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            MessageWebView(html: ThreadHTML.render(messages: detail.messages))
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
    /// stylesheets can't bleed into each other or the chrome. A parent
    /// script sizes the frames and routes link clicks to the system browser.
    static func render(messages: [Message]) -> String {
        let sections = messages.map { m in
            let body: String
            if let html = m.bodyHTML, !html.isEmpty {
                body = "<iframe class=\"frame\" sandbox=\"allow-same-origin\" srcdoc=\"\(escapeAttr(frameDoc(html)))\"></iframe>"
            } else {
                body = "<div class='plain'>\(escape(m.bodyText ?? ""))</div>"
            }
            let date = m.date.formatted(date: .abbreviated, time: .shortened)
            return """
            <section class="msg">
              <div class="hdr">
                <span class="from">\(escape(m.fromName))</span>
                <span class="addr">&lt;\(escape(m.fromEmail))&gt;</span>
                <span class="date">\(escape(date))</span>
                <div class="to">to \(escape(m.toList))</div>
              </div>
              \(body)
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
          .msg { padding: 14px 16px; border-bottom: 1px solid rgba(128,128,128,0.25); }
          .hdr { margin-bottom: 10px; }
          .from { font-weight: 600; }
          .addr, .date, .to { color: gray; font-size: 12px; }
          .date { float: right; }
          .plain { white-space: pre-wrap; overflow-x: auto; }
          .frame { width: 100%; border: none; height: 120px; background: #fff; border-radius: 4px; }
        </style></head><body>\(sections)
        <script>
        function fit(f) {
          try {
            var d = f.contentDocument;
            if (!d || !d.documentElement) return;
            f.style.height = Math.min(d.documentElement.scrollHeight + 24, 20000) + 'px';
            if (!f.dataset.hooked) {
              f.dataset.hooked = '1';
              d.addEventListener('click', function (e) {
                var a = e.target.closest ? e.target.closest('a') : null;
                if (a && a.href) { e.preventDefault(); window.location.href = a.href; }
              }, true);
            }
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

// MARK: - WKWebView wrapper (no JS, links open externally)

#if os(macOS)
struct MessageWebView: NSViewRepresentable {
    let html: String

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

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Parent page JS sizes the message iframes; email content itself
        // stays script-free (iframe sandbox has no allow-scripts).
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
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

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Any http(s) navigation (link click or the iframe click-forwarder
        // setting window.location) opens in the system browser instead.
        if let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
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
