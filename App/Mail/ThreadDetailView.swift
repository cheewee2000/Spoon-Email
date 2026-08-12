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
    static func render(messages: [Message]) -> String {
        let sections = messages.map { m in
            let body: String
            if let html = m.bodyHTML, !html.isEmpty {
                body = html
            } else {
                body = "<div style='white-space:pre-wrap'>\(escape(m.bodyText ?? ""))</div>"
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
              <div class="body">\(body)</div>
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
          .body { overflow-x: auto; }
          .body img { max-width: 100%; height: auto; }
          blockquote { border-left: 2px solid rgba(128,128,128,0.4); margin: 8px 0; padding-left: 10px; color: gray; }
        </style></head><body>\(sections)</body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - WKWebView wrapper (no JS, links open externally)

#if os(macOS)
struct MessageWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
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
        config.defaultWebpagePreferences.allowsContentJavaScript = false
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
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
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
