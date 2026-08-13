import SwiftUI
import MailCore

struct ThreadListView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var listModel: ThreadListModel
    @Binding var selection: MailThread?
    var searchQuery: String?

    var body: some View {
        List(selection: Binding(
            get: { selection?.key },
            set: { key in selection = listModel.threads.first { $0.key == key } }
        )) {
            // NavigationLink, not a bare .tag: on iOS a List selection binding
            // only reacts to taps in edit mode, so tagged rows are dead to
            // touch. A link with a value matching the selection type drives
            // the split view on both platforms (and pushes when collapsed).
            ForEach(listModel.threads, id: \.key) { thread in
                NavigationLink(value: thread.key) {
                    ThreadRow(thread: thread, accountColor: model.accountColor(thread.accountId))
                }
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
                }
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

struct ThreadRow: View {
    let thread: MailThread
    let accountColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? accountColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.participants.isEmpty ? "(unknown)" : thread.participants)
                        .font(.system(size: 13, weight: thread.isUnread ? .bold : .regular))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if thread.hasDraft {
                        Text("Draft")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
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
