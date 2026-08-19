import SwiftUI
import MailCore

struct ThreadListView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var listModel: ThreadListModel
    @Binding var selection: MailThread?
    var searchQuery: String?

    var body: some View {
        threadList
            // Row .onAppear is unreliable in macOS List, so page in more
            // threads from the actual scroll position instead.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 800
            } action: { _, nearBottom in
                if nearBottom { listModel.loadMore(db: model.db) }
            }
    }

    private var threadList: some View {
        List(selection: Binding(
            get: { selection?.key },
            set: { key in selection = listModel.threads.first { $0.key == key } }
        )) {
            ForEach(listModel.threads, id: \.key) { thread in
                ThreadRow(thread: thread, accountColor: model.accountColor(thread.accountId))
                    .collapsed(listModel.collapsing.contains(thread.key))
                    .tag(thread.key)
                    .listRowSeparatorTint(CWT.hairline)
                    .swipeActions(edge: .trailing) {
                        Button {
                            model.archive(thread)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(CWT.green)
                    }
                    .contextMenu { ThreadContextMenu(thread: thread) }
                    .hotkeyHoverTarget(thread, model: model)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CWT.paper)
        .onKeyPress(phases: .down) { press in
            handleKey(press)
        }
        .overlay {
            if listModel.threads.isEmpty {
                if searchQuery != nil {
                    EmptyState(title: "No results", systemImage: "magnifyingglass",
                               detail: "Nothing on this Mac matches.")
                } else if listModel.filter == .spam {
                    EmptyState(title: "No spam", systemImage: "xmark.bin",
                               detail: "Gmail's spam folder is empty.")
                } else if listModel.filter == .blocked {
                    EmptyState(title: "Nothing blocked", systemImage: "hand.raised",
                               detail: "Block a sender or domain from a message's ••• menu.")
                } else {
                    EmptyState(title: "Inbox zero", systemImage: "checkmark.circle",
                               detail: "Nothing here.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let query = searchQuery {
                Button {
                    model.serverSearch(query)
                } label: {
                    Label("Search Gmail for older mail", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.square)
                .padding(6)
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        let threads = listModel.threads
        switch press.characters {
        case "j":
            model.selectNext(in: threads)
        case "k":
            model.selectPrevious(in: threads)
        case "e":
            model.archiveSelected(in: threads)
        case "u":
            if let t = selection { model.markRead(t, read: t.isUnread) }
        case "s":
            if let t = selection { model.toggleStar(t) }
        case "o":
            if let t = selection { model.toggleOpen(t) }
        case "r":
            if let t = selection { model.reply(to: t, all: false) }
        case "a":
            if let t = selection { model.reply(to: t, all: true) }
        case "f":
            if let t = selection { model.forward(t) }
        case "c":
            model.compose()
        default:
            return .ignored
        }
        return .handled
    }
}

extension View {
    /// Makes this row the triage-hotkey target while the pointer is over it —
    /// applied to rows in both the full-width list and the board columns.
    func hotkeyHoverTarget(_ thread: MailThread, model: AppModel) -> some View {
        modifier(HotkeyHoverTarget(thread: thread, model: model))
    }
}

extension View {
    /// Row-collapse used when a thread is archived/trashed: height and
    /// opacity go to zero (animated by the caller's transaction) while the
    /// row keeps its identity, so the rows below slide up to fill the gap.
    func collapsed(_ isCollapsed: Bool) -> some View {
        self
            .frame(height: isCollapsed ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(isCollapsed ? 0 : 1)
            .listRowInsets(isCollapsed ? EdgeInsets() : nil)
    }
}

/// Tracks the pointer per row: publishes the row to AppModel as the hotkey
/// target and tints it so you can see which row a keystroke will hit. The
/// onChange keeps the captured snapshot fresh when the row re-renders under
/// a stationary cursor (e.g. `u` flipping isUnread); without it a second
/// keystroke would act on the pre-toggle flags.
private struct HotkeyHoverTarget: ViewModifier {
    let thread: MailThread
    let model: AppModel
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? CWT.hover : Color.clear)
            .onHover { inside in
                hovering = inside
                if inside {
                    model.hoveredThread = thread
                } else if model.hoveredThread?.key == thread.key {
                    model.hoveredThread = nil
                }
            }
            .onChange(of: thread) { _, fresh in
                if model.hoveredThread?.key == fresh.key { model.hoveredThread = fresh }
            }
    }
}

struct ThreadRow: View {
    let thread: MailThread
    let accountColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Account accent: every row carries its account's color so
            // mail from different accounts is tellable at a glance.
            Rectangle()
                .fill(accountColor)
                .frame(width: 2)
            Rectangle()
                .fill(thread.isUnread ? accountColor : .clear)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            AvatarView(name: thread.participants,
                       email: thread.lastSenderEmail,
                       size: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.participants.isEmpty ? "(unknown)" : thread.participants)
                        .font(CWT.font(12, bold: thread.isUnread))
                        .foregroundStyle(CWT.ink)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(CWT.font(10))
                            .foregroundStyle(CWT.ink3)
                    }
                    if thread.hasDraft {
                        // A word-sized badge crowded out the sender on every
                        // row in Drafts, where every row has one; the dot says
                        // the same thing at a glance.
                        Tag(text: "DRAFT", color: CWT.orange, inverted: false)
                            .help("Unsent draft")
                    }
                    Spacer()
                    if thread.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10))
                            .foregroundStyle(CWT.ink3)
                    }
                    if thread.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(CWT.orange)
                    }
                    Text(Self.relativeDate(thread.lastDate))
                        .font(CWT.font(10))
                        .foregroundStyle(CWT.ink3)
                        .monospacedDigit()
                }
                Text(thread.subject)
                    .font(CWT.font(12, bold: thread.isUnread))
                    .foregroundStyle(CWT.ink)
                    .lineLimit(1)
                Text(thread.snippet)
                    .font(CWT.font(11))
                    .foregroundStyle(CWT.ink2)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    static func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
