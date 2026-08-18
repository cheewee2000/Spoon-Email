import SwiftUI
import MailCore

/// The right-click menu for a thread row: its status and labels as check
/// marks you can flip, plus "move to" for the folder-minded. Shared by every
/// list that shows threads.
struct ThreadContextMenu: View {
    let thread: MailThread
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Read once per menu open; the row itself only carries the few
        // denormalized flags.
        let labels = model.labelIds(of: thread)
        let inInbox = labels.contains(GmailLabels.inbox)
        let userLabels = model.userLabels[thread.accountId] ?? []

        toggle("Inbox", on: inInbox) { model.setLabel(GmailLabels.inbox, on: $0, for: thread) }
        toggle("Unread", on: thread.isUnread) { model.markRead(thread, read: !$0) }
        toggle("Starred", on: thread.isStarred) { _ in model.toggleStar(thread) }
        toggle("Important", on: labels.contains(GmailLabels.important)) {
            model.setLabel(GmailLabels.important, on: $0, for: thread)
        }
        toggle("Open", on: thread.isOpen) { _ in model.toggleOpen(thread) }

        Divider()

        Menu("Labels") {
            ForEach(userLabels) { label in
                toggle(label.name, on: labels.contains(label.id)) {
                    model.setLabel(label.id, on: $0, for: thread)
                }
            }
            if !userLabels.isEmpty { Divider() }
            Button("New Label…") { model.promptNewLabel(for: thread, move: false) }
        }
        Menu("Move to") {
            if !inInbox {
                Button("Inbox") { model.unarchive(thread) }
                Divider()
            }
            ForEach(userLabels) { label in
                Button(label.name) { model.move(thread, toLabel: label.id) }
            }
            if !userLabels.isEmpty { Divider() }
            Button("New Label…") { model.promptNewLabel(for: thread, move: true) }
        }

        Divider()

        if inInbox {
            Button("Archive") { model.archive(thread) }
        } else {
            Button("Move to Inbox") { model.unarchive(thread) }
        }
    }

    private func toggle(_ title: String, on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { set($0) }))
    }
}
