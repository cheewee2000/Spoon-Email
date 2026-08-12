import SwiftUI
import MailCore

struct ThreadListView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var listModel: ThreadListModel
    @Binding var selection: MailThread?

    var body: some View {
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
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if listModel.threads.isEmpty {
                ContentUnavailableView(
                    "Inbox Zero",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing here.")
                )
            }
        }
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
                    Spacer()
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
