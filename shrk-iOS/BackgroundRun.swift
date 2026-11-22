//
//  BackgroundRun.swift
//  shrk (iOS)
//
//  Lets a compression run keep going when the user leaves the app, using
//  iOS 26's continued processing tasks: the system shows the progress, and
//  the user can stop it from there. The screen is also kept awake while the
//  app is open.
//

import BackgroundTasks
import UIKit

@MainActor
final class BackgroundRun {
    /// Called when iOS ends the task early (or the user stops it from the
    /// system's progress UI). Treat it like Stop.
    var onExpire: (() -> Void)?

    private var task: BGContinuedProcessingTask?
    private var isActive = false
    private var pendingProgress: (done: Double, total: Int, subtitle: String) = (0, 1, "")

    func begin(total: Int) {
        end(success: true)
        isActive = true
        pendingProgress = (0, max(total, 1), "Starting…")
        UIApplication.shared.isIdleTimerDisabled = true

        // Must match BGTaskSchedulerPermittedIdentifiers ("<bundle id>.compress.*").
        let identifier = "\(Bundle.main.bundleIdentifier ?? "ht.shrk.ios").compress.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.isActive, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else { return }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Compressing videos",
            subtitle: "Starting…"
        )
        request.strategy = .queue
        try? BGTaskScheduler.shared.submit(request)
    }

    /// `done` counts finished videos plus the fraction of the current one.
    func update(done: Double, total: Int, subtitle: String) {
        pendingProgress = (done, max(total, 1), subtitle)
        guard let task else { return }
        task.progress.totalUnitCount = Int64(pendingProgress.total * 1000)
        task.progress.completedUnitCount = Int64(min(done, Double(pendingProgress.total)) * 1000)
        task.updateTitle("Compressing videos", subtitle: subtitle)
    }

    func end(success: Bool) {
        isActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        task?.setTaskCompleted(success: success)
        task = nil
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                self.onExpire?()
            }
        }
        update(done: pendingProgress.done, total: pendingProgress.total, subtitle: pendingProgress.subtitle)
    }
}
