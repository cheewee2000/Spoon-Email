#if os(iOS)
import Foundation
import BackgroundTasks

/// iOS-only: keeps mail arriving while the app is backgrounded.
///
/// There is no server and no APNs here — iOS wakes the app on its own
/// schedule (opportunistic, typically 15 minutes to a few hours, and never
/// while the app is force-quit), we run one incremental pass, and the local
/// notifications that pass raises are the "push".
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in App/Info.plist.
    static let taskID = "com.cwandt.spoon.refresh"

    /// Has to happen before launch finishes, so it lives in the App's init.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Throws when the app is in a state that can't hold a request (no
        // background refresh permission, low power mode). Nothing to do about
        // it — the foreground sync still covers us.
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Queue the next one first: if this pass crashes or expires, the
        // chain is already re-armed.
        schedule()

        let work = Task { @MainActor in
            await AppModel.shared.syncAndWait()
        }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: true)
        }
    }
}
#endif
