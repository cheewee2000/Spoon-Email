import WidgetKit
import SwiftUI

// MARK: - Style (mirrors App/Theme.swift; the extension is its own process)

private enum W {
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.067, alpha: 1) : .white })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.965, green: 0.961, blue: 0.949, alpha: 1) : UIColor(white: 0.067, alpha: 1) })
    static let ink2 = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.69, alpha: 1) : UIColor(white: 0.29, alpha: 1) })
    static let ink3 = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.48, alpha: 1) : UIColor(white: 0.54, alpha: 1) })
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.165, alpha: 1) : UIColor(white: 0.89, alpha: 1) })
    static let red = Color(red: 0xd1 / 255, green: 0x1d / 255, blue: 0x1d / 255)

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size)
    }
}

private extension Color {
    init(hex: String) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x111111
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Timeline

struct InboxEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct InboxProvider: TimelineProvider {
    func placeholder(in context: Context) -> InboxEntry {
        InboxEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (InboxEntry) -> Void) {
        completion(InboxEntry(date: .now, snapshot: context.isPreview
                              ? .sample : (WidgetSnapshotStore.load() ?? .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InboxEntry>) -> Void) {
        // The app reloads this timeline whenever the snapshot changes; the
        // refresh here only keeps the relative dates honest overnight.
        let entry = InboxEntry(date: .now, snapshot: WidgetSnapshotStore.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

extension WidgetSnapshot {
    static let sample = WidgetSnapshot(
        generatedAt: .now, unifiedUnread: 3, openUnread: 1,
        threads: [
            .init(accountId: "a", threadId: "1", participants: "Taylor Levy",
                  subject: "Pen Type-C: sleeve tolerance", snippet: "The 3.5 mm sleeve is holding at ±0.02.",
                  lastDate: .now.addingTimeInterval(-600), isUnread: true, isOpen: false, colorHex: "#D11D1D"),
            .init(accountId: "a", threadId: "2", participants: "Vermont shop",
                  subject: "Grade 5 titanium — lot 1610", snippet: "Certs attached. Ships Thursday.",
                  lastDate: .now.addingTimeInterval(-7200), isUnread: true, isOpen: false, colorHex: "#E35A1E"),
            .init(accountId: "a", threadId: "3", participants: "Kickstarter",
                  subject: "Your project update was published", snippet: "Update #12 is live.",
                  lastDate: .now.addingTimeInterval(-86400), isUnread: false, isOpen: false, colorHex: "#2E7D4F"),
            .init(accountId: "a", threadId: "4", participants: "Che-Wei Wang",
                  subject: "Time Since Launch firmware", snippet: "Counter rolls over at 2^32 seconds.",
                  lastDate: .now.addingTimeInterval(-90000), isUnread: false, isOpen: true, colorHex: "#B08D57"),
        ])
}

// MARK: - Views

private func relativeDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(W.hairline).frame(height: 1) }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(W.font(9, bold: true)).tracking(0.4).foregroundStyle(W.ink3)
    }
}

private struct CountBlock: View {
    let count: Int
    let label: String
    var big = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(count)")
                .font(W.font(big ? 34 : 20, bold: true))
                .foregroundStyle(count > 0 ? W.ink : W.ink3)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
            SectionLabel(text: label)
        }
    }
}

private struct ThreadLine: View {
    let item: WidgetSnapshot.Item
    var showSnippet = false
    var body: some View {
        Link(destination: SpoonURL.thread(accountId: item.accountId, threadId: item.threadId)) {
            HStack(alignment: .top, spacing: 6) {
                Rectangle().fill(Color(hex: item.colorHex)).frame(width: 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.participants.isEmpty ? "(unknown)" : item.participants)
                            .font(W.font(11, bold: item.isUnread))
                            .foregroundStyle(W.ink)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(relativeDate(item.lastDate))
                            .font(W.font(9))
                            .foregroundStyle(W.ink3)
                            .monospacedDigit()
                    }
                    Text(item.subject)
                        .font(W.font(10, bold: item.isUnread))
                        .foregroundStyle(item.isUnread ? W.ink : W.ink2)
                        .lineLimit(1)
                    if showSnippet {
                        Text(item.snippet)
                            .font(W.font(9))
                            .foregroundStyle(W.ink3)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct InboxWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: InboxEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            default: large
            }
        }
        .containerBackground(W.paper, for: .widget)
        .widgetURL(SpoonURL.mailbox("unified"))
    }

    private var s: WidgetSnapshot { entry.snapshot }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("CW&T").font(W.font(9, bold: true)).tracking(0.4).foregroundStyle(W.ink3)
                Spacer()
                if s.openUnread > 0 { tag("OPEN \(s.openUnread)") }
            }
            Spacer(minLength: 0)
            CountBlock(count: s.unifiedUnread, label: "Unread")
            Hairline()
            if let first = s.threads.first(where: { $0.isUnread }) ?? s.threads.first {
                Text(first.participants).font(W.font(10, bold: first.isUnread)).foregroundStyle(W.ink).lineLimit(1)
                Text(first.subject).font(W.font(9)).foregroundStyle(W.ink2).lineLimit(1)
            } else {
                Text("Inbox zero").font(W.font(10)).foregroundStyle(W.ink3)
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CW&T").font(W.font(9, bold: true)).tracking(0.4).foregroundStyle(W.ink3)
                Spacer(minLength: 0)
                CountBlock(count: s.unifiedUnread, label: "Unread")
                CountBlock(count: s.openUnread, label: "Open", big: false)
            }
            .frame(width: 72, alignment: .leading)
            Rectangle().fill(W.hairline).frame(width: 1)
            list(limit: 3, snippet: false)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("CW&T").font(W.font(9, bold: true)).tracking(0.4).foregroundStyle(W.ink3)
                SectionLabel(text: "Unified")
                Spacer()
                Text("\(s.unifiedUnread) unread").font(W.font(10)).foregroundStyle(W.ink2)
                if s.openUnread > 0 { tag("OPEN \(s.openUnread)") }
            }
            Hairline()
            list(limit: 7, snippet: true)
        }
    }

    private func list(limit: Int, snippet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if s.threads.isEmpty {
                Text("Inbox zero").font(W.font(10)).foregroundStyle(W.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ForEach(Array(s.threads.prefix(limit).enumerated()), id: \.element) { i, item in
                    if i > 0 { Hairline() }
                    ThreadLine(item: item, showSnippet: snippet)
                        .padding(.vertical, snippet ? 5 : 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(W.font(8, bold: true)).tracking(0.4)
            .foregroundStyle(W.paper)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(W.red)
    }
}

// MARK: - Widget

struct SpoonInboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.widgetKind, provider: InboxProvider()) { entry in
            InboxWidgetView(entry: entry)
        }
        .configurationDisplayName("Unified Inbox")
        .description("Unread count and the newest mail across your accounts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct SpoonWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SpoonInboxWidget()
    }
}
