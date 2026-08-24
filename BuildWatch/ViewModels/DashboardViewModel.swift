import Foundation
import SwiftUI
import UserNotifications

/// Haptic vocabulary. The app previously shipped with no tactile feedback of any kind:
/// a refresh that found nothing and a refresh that turned your push red felt identical.
nonisolated enum HapticEvent: Equatable {
    case refreshed
    case pushPassed
    case pushFailed
    case watchToggled
    case actionFailed

    var feedback: SensoryFeedback {
        switch self {
        case .refreshed:    .impact(weight: .light, intensity: 0.5)
        case .pushPassed:   .success
        case .pushFailed:   .error
        case .watchToggled: .selection
        case .actionFailed: .warning
        }
    }
}

nonisolated struct HapticSignal: Equatable {
    var event: HapticEvent
    var tick: Int
}

@Observable
final class DashboardViewModel {

    var pushes: [Push] = []
    var jobsByPush: [Int: [Job]] = [:]
    var failureLinesByPush: [Int: [TextLogError]] = [:]
    var isRefreshing = false
    var errorMessage: String?
    var lastRefresh: Date?
    var watchedPushIds: Set<Int> = []

    /// Derived job state, computed once per ingest instead of once per frame per row.
    private(set) var summaries: [Int: PushSummary] = [:]

    /// Server-supplied `last_modified` high-water mark per push, driving delta refreshes.
    private var watermarks: [Int: String] = [:]

    private(set) var haptic = HapticSignal(event: .refreshed, tick: 0)
    private var notifiedPushIds: Set<Int> = []

    /// How many pushes get their jobs loaded eagerly on the list screen.
    private let eagerPushCount = 5

    init() {
        let stored = UserDefaults.standard.array(forKey: "watchedPushIds") as? [Int] ?? []
        watchedPushIds = Set(stored)
    }

    var username: String {
        UserDefaults.standard.string(forKey: "username") ?? ""
    }

    var usernameHandle: String {
        username.components(separatedBy: "@").first.flatMap { $0.isEmpty ? nil : $0 } ?? "Try"
    }

    // MARK: - Derived State

    func summary(for push: Push) -> PushSummary? { summaries[push.id] }

    func platformGroups(for push: Push) -> [PlatformGroup] { summaries[push.id]?.groups ?? [] }

    func failureCount(_ push: Push) -> Int { summaries[push.id]?.failureCount ?? 0 }

    func isRunning(_ push: Push) -> Bool { summaries[push.id]?.isRunning ?? false }

    func hasLoadedJobs(_ push: Push) -> Bool { summaries[push.id] != nil }

    /// True while any loaded push still has work outstanding — used to poll faster.
    var anyPushRunning: Bool {
        summaries.values.contains { $0.isRunning }
    }

    // MARK: - Haptics

    func emit(_ event: HapticEvent) {
        haptic = HapticSignal(event: event, tick: haptic.tick &+ 1)
    }

    // MARK: - Watch / Notify

    func toggleWatch(push: Push) {
        if watchedPushIds.contains(push.id) {
            watchedPushIds.remove(push.id)
        } else {
            watchedPushIds.insert(push.id)
            Task { await requestNotificationPermissionIfNeeded() }
            checkCompletion(for: push)
        }
        emit(.watchToggled)
        persistWatchList()
    }

    private func persistWatchList() {
        UserDefaults.standard.set(Array(watchedPushIds), forKey: "watchedPushIds")
    }

    private func checkCompletion(for push: Push) {
        guard watchedPushIds.contains(push.id),
              !notifiedPushIds.contains(push.id),
              let summary = summaries[push.id],
              summary.isComplete
        else { return }

        notifiedPushIds.insert(push.id)
        watchedPushIds.remove(push.id)
        persistWatchList()

        let failures = summary.failureCount + summary.lowerTierFailures
        emit(failures == 0 ? .pushPassed : .pushFailed)
        sendNotification(for: push, failures: failures, summary: summary)
    }

    private func sendNotification(for push: Push, failures: Int, summary: PushSummary) {
        let content = UNMutableNotificationContent()
        content.title = failures == 0
            ? "Try push passed"
            : "Try push failed — \(failures) job\(failures == 1 ? "" : "s")"
        content.body = push.displayTitle
        content.subtitle = "\(summary.successCount) passed · \(summary.totalCount) jobs"
        content.sound = .default
        content.userInfo = ["pushId": push.id]
        content.interruptionLevel = failures == 0 ? .active : .timeSensitive

        let request = UNNotificationRequest(
            identifier: "buildwatch-\(push.id)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermissionIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    // MARK: - Data Loading

    /// Reloads the push list, then re-reads jobs for every push already on screen.
    ///
    /// Previously this only re-read jobs for *watched* pushes: `fetchJobs` bailed out
    /// whenever a push already had cached jobs, so pull-to-refresh moved the timestamp
    /// but left every status dot frozen at whatever it was on first load. A running job
    /// never turned green until the app was killed.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let author = username.isEmpty ? nil : username
            let fetched = try await TreeHerderService.shared.fetchPushes(count: 20, author: author)
            pushes = fetched
            lastRefresh = Date()

            await refreshJobs(for: refreshTargets(from: fetched))
            emit(.refreshed)
        } catch {
            errorMessage = error.localizedDescription
            emit(.actionFailed)
        }
    }

    /// A background poll: same job refresh, without disturbing the push list or the
    /// pull-to-refresh spinner.
    func poll() async {
        guard !isRefreshing, !pushes.isEmpty else { return }
        await refreshJobs(for: pollTargets(from: pushes))
    }

    /// What the 30-second timer re-reads: the head of the list plus anything watched.
    ///
    /// Deliberately narrower than `refreshTargets`. Rows load their jobs on appear, so
    /// scrolling the whole list would otherwise leave 20 pushes eligible for every tick —
    /// ~40 requests a minute against a shared public service, forever, in the background.
    /// Capping the automatic path keeps the steady state at `eagerPushCount` + watched.
    private func pollTargets(from candidates: [Push]) -> [Push] {
        candidates.enumerated()
            .filter { index, push in
                index < eagerPushCount || watchedPushIds.contains(push.id)
            }
            .map(\.element)
    }

    /// What an explicit pull-to-refresh re-reads: everything already on screen.
    ///
    /// Wider than `pollTargets` on purpose. A manual pull is user-initiated and
    /// infrequent, and a push the user has scrolled to and is looking at should update
    /// when they ask it to — that staleness is the whole bug this change exists to fix.
    private func refreshTargets(from candidates: [Push]) -> [Push] {
        candidates.enumerated()
            .filter { index, push in
                index < eagerPushCount
                    || watchedPushIds.contains(push.id)
                    || summaries[push.id] != nil
            }
            .map(\.element)
    }

    private func refreshJobs(for targets: [Push]) async {
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for push in targets {
                group.addTask { [weak self] in await self?.loadJobs(for: push, force: true) }
            }
        }
    }

    /// Loads jobs for a push. Cheap to call repeatedly: once a push has been read, later
    /// calls ask TreeHerder only for rows whose `last_modified` moved, and merge them in.
    func fetchJobs(for push: Push) async {
        guard summaries[push.id] == nil else { return }
        await loadJobs(for: push, force: false)
    }

    private func loadJobs(for push: Push, force: Bool) async {
        let existing = jobsByPush[push.id]
        let watermark = force ? watermarks[push.id] : nil

        // Only a push we've already read in full can be updated incrementally.
        let since = (existing == nil) ? nil : watermark

        guard let snapshot = try? await TreeHerderService.shared.fetchJobs(
            pushId: push.id,
            modifiedSince: since
        ) else { return }

        apply(snapshot, to: push, hadExistingJobs: since != nil)
    }

    private func apply(_ snapshot: JobsSnapshot, to push: Push, hadExistingJobs: Bool) {
        let merged: [Job]
        if hadExistingJobs, let existing = jobsByPush[push.id] {
            if snapshot.jobs.isEmpty {
                // Nothing changed server-side — leave state (and the view) untouched.
                if let mark = snapshot.latestModified { watermarks[push.id] = max(mark, watermarks[push.id] ?? mark) }
                return
            }
            merged = Self.merge(existing: existing, delta: snapshot.jobs)
        } else {
            merged = snapshot.jobs
        }

        jobsByPush[push.id] = merged
        summaries[push.id] = PushSummary(jobs: merged)
        if let mark = snapshot.latestModified {
            watermarks[push.id] = max(mark, watermarks[push.id] ?? mark)
        }
        checkCompletion(for: push)
    }

    /// Replaces changed rows in place and appends genuinely new ones, so the server's
    /// ordering survives a delta.
    nonisolated static func merge(existing: [Job], delta: [Job]) -> [Job] {
        var indexByID = [Int: Int](minimumCapacity: existing.count)
        for (i, job) in existing.enumerated() { indexByID[job.id] = i }

        var merged = existing
        for job in delta {
            if let i = indexByID[job.id] {
                merged[i] = job
            } else {
                indexByID[job.id] = merged.count
                merged.append(job)
            }
        }
        return merged
    }

    // MARK: - Failure Lines

    /// How many failed jobs the Failure Summary pulls logs for. One request per job, so this
    /// is a deliberate ceiling on a burst against a shared public service — but it means a
    /// push with more failures than this is *sampled*, not summarised. `failureSample`
    /// reports that so the sheet can say so out loud instead of presenting a truncated
    /// count as the whole picture.
    static let failureLogSampleLimit = 15

    /// `(sampled, total)` failed jobs for a push. `sampled < total` means the cap bit.
    func failureSample(for push: Push) -> (sampled: Int, total: Int) {
        let total = (jobsByPush[push.id] ?? [])
            .count { $0.result.isFailure && $0.state == .completed }
        return (min(total, Self.failureLogSampleLimit), total)
    }

    func fetchFailureLines(for push: Push) async {
        guard failureLinesByPush[push.id] == nil else { return }
        let failed = Array((jobsByPush[push.id] ?? [])
            .filter { $0.result.isFailure && $0.state == .completed }
            .prefix(Self.failureLogSampleLimit))
        guard !failed.isEmpty else {
            failureLinesByPush[push.id] = []
            return
        }
        var allErrors: [TextLogError] = []
        await withTaskGroup(of: [TextLogError].self) { group in
            for job in failed {
                group.addTask {
                    (try? await TreeHerderService.shared.fetchTextLogErrors(jobId: job.id)) ?? []
                }
            }
            for await errors in group {
                allErrors.append(contentsOf: errors)
            }
        }
        failureLinesByPush[push.id] = allErrors
    }

    func failureGroups(for push: Push) -> [FailureGroup] {
        let errors = failureLinesByPush[push.id] ?? []
        var byKey: [String: (jobs: Set<Int>, first: String)] = [:]
        for error in errors {
            let key = error.groupKey
            var entry = byKey[key] ?? (jobs: [], first: error.line)
            entry.jobs.insert(error.job)
            byKey[key] = entry
        }
        return byKey.map { key, val in
            FailureGroup(id: key, pattern: key, affectedJobCount: val.jobs.count, exampleLine: val.first)
        }.sorted { $0.affectedJobCount > $1.affectedJobCount }
    }
}
