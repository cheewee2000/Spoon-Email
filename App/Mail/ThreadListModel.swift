import Foundation
import SwiftUI
import GRDB
import MailCore

/// Live thread list for one mailbox, backed by GRDB ValueObservation.
@MainActor
final class ThreadListModel: ObservableObject {
    @Published private(set) var threads: [MailThread] = []
    private var cancellable: AnyDatabaseCancellable?
    private(set) var filter: MailboxFilter = .unified

    func observe(db: AppDatabase, filter: MailboxFilter) {
        self.filter = filter
        cancellable?.cancel()
        let observation = ValueObservation.tracking { db in
            try filter.fetch(db)
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("thread observation error: \(error)")
        } onChange: { [weak self] threads in
            self?.threads = threads
        }
    }
}

/// Live message list for one thread.
@MainActor
final class ThreadDetailModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    private var cancellable: AnyDatabaseCancellable?

    func observe(db: AppDatabase, thread: MailThread) {
        cancellable?.cancel()
        let accountId = thread.accountId
        let threadId = thread.id
        let observation = ValueObservation.tracking { db in
            try Message.fetchAll(
                db,
                sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY date",
                arguments: [accountId, threadId])
        }
        cancellable = observation.start(
            in: db.writer,
            scheduling: .async(onQueue: .main)
        ) { error in
            print("message observation error: \(error)")
        } onChange: { [weak self] messages in
            self?.messages = messages
        }
    }
}
