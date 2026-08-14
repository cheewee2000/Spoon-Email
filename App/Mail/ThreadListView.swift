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
                    .tag(thread.key)
                    .swipeActions(edge: .trailing) {
                        Button {
                            model.archive(thread)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button("Archive") { model.archive(thread) }
                        Button(thread.isUnread ? "Mark Read" : "Mark Unread") {
                            model.markRead(thread, read: thread.isUnread)
                        }
                        Button(thread.isStarred ? "Unstar" : "Star") {
                            model.toggleStar(thread)
                        }
                        Button(thread.isOpen ? "Remove from Open" : "Mark Open") {
                            model.toggleOpen(thread)
                        }
                    }
                    .hotkeyHoverTarget(thread, model: model)
            }
        }
        .listStyle(.plain)
        .onKeyPress(phases: .down) { press in
            handleKey(press)
        }
        .overlay {
            if listModel.threads.isEmpty {
                if searchQuery != nil {
                    ContentUnavailableView.search
                } else if listModel.filter == .blocked {
                    ContentUnavailableView(
                        "Nothing Blocked",
                        systemImage: "hand.raised",
                        description: Text("Block a sender or domain from a message's ••• menu.")
                    )
                } else {
                    ContentUnavailableView(
                        "Inbox Zero",
                        systemImage: "checkmark.circle",
                        description: Text("Nothing here.")
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let query = searchQuery {
                Button {
                    model.serverSearch(query)
                } label: {
                    Label("Search Gmail for older mail", systemImage: "icloud.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
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
    /// The onChange keeps the captured snapshot fresh when the row re-renders
    /// under a stationary cursor (e.g. `u` flipping isUnread); without it a
    /// second keystroke would act on the pre-toggle flags.
    func hotkeyHoverTarget(_ thread: MailThread, model: AppModel) -> some View {
        self
            .onHover { inside in
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
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accountColor.opacity(0.8))
                .frame(width: 3)
            Circle()
                .fill(thread.isUnread ? accountColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            AvatarView(name: thread.participants,
                       email: thread.lastSenderEmail,
                       size: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.participants.isEmpty ? "(unknown)" : thread.participants)
                        .font(.system(size: 13, weight: thread.isUnread ? .bold : .regular))
                        .foregroundStyle(thread.isUnread ? accountColor : .primary)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if thread.hasDraft {
                        // A word-sized badge crowded out the sender on every
                        // row in Drafts, where every row has one; the dot says
                        // the same thing at a glance.
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .help("Unsent draft")
                    }
                    Spacer()
                    if thread.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if thread.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                    Text(Self.relativeDate(thread.lastDate))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(thread.subject)
                    .font(.system(size: 12, weight: thread.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                Text(thread.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
