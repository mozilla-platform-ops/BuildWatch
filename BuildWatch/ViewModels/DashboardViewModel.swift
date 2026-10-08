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

    /// Push Health per push: the row summary, and the full report once a push is opened.
    private(set) var healthSummaries: [Int: HealthSummary] = [:]
    private(set) var healths: [Int: PushHealth] = [:]

    /// Per failed job, fetched when its card is opened.
    private(set) var suggestions: [Int: [BugSuggestion]] = [:]
    private(set) var jobDetails: [Int: JobDetail] = [:]
    /// The first failing test in a job's log, for naming "Seen before" failures. A job
    /// whose log names no test maps to "".
    private(set) var firstFailingTest: [Int: String] = [:]

    /// People whose pushes were looked at, newest first, as on the web's picker.
    private(set) var people: [Person] = []

    /// Whose pushes the list shows. Stored under the key Settings used, so an existing
    /// install keeps its address.
    private(set) var username: String

    private let gate = RequestGate(limit: 4)
    /// Push Health prefetches are slow on Treeherder's side, so at most two run at once.
    private let prefetchGate = RequestGate(limit: 2)
    private var healthTasks: [Int: Task<Void, Never>] = [:]

    init() {
        let stored = UserDefaults.standard.array(forKey: "watchedPushIds") as? [Int] ?? []
        watchedPushIds = Set(stored)
        username = UserDefaults.standard.string(forKey: "username") ?? ""
        if let data = UserDefaults.standard.data(forKey: "people"),
           let saved = try? JSONDecoder().decode([Person].self, from: data) {
            people = saved
        }
    }

    // MARK: - Author

    func show(author: String) {
        let email = author.trimmingCharacters(in: .whitespaces).lowercased()
        guard email.contains("@"), email != username else { return }
        username = email
        UserDefaults.standard.set(email, forKey: "username")
        pushes = []
        errorMessage = nil
        Task { await refresh() }
    }

    /// The pusher's name, from their commits, once a push of theirs has loaded.
    var authorName: String? {
        pushes.first { $0.author.lowercased() == username }?.authorName
    }

    func personName(_ email: String) -> String? {
        people.first { $0.email == email }?.name
    }

    func rememberPerson(_ email: String, name: String?) {
        let key = email.lowercased()
        guard key.contains("@") else { return }
        let known = people.first { $0.email == key }
        let person = Person(email: key, name: name ?? known?.name)
        guard people.first != person else { return }
        people = Array(([person] + people.filter { $0.email != key }).prefix(8))
        savePeople()
    }

    func clearPeople() {
        people = []
        savePeople()
    }

    private func savePeople() {
        UserDefaults.standard.set(try? JSONEncoder().encode(people), forKey: "people")
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
            if let own = fetched.first(where: { $0.author.lowercased() == username }) {
                rememberPerson(username, name: own.authorName)
            }

            let targets = refreshTargets(from: fetched)
            async let summaries: Void = refreshHealthSummaries(for: targets)
            await refreshJobs(for: targets)
            await summaries
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
        let targets = pollTargets(from: pushes)
        async let summaries: Void = refreshHealthSummaries(for: targets)
        await refreshJobs(for: targets)
        await summaries
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

    /// Re-reads one push's jobs, as a delta when it has been read before.
    func reload(_ push: Push) async {
        await loadJobs(for: push, force: true)
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
        summaries[push.id] = PushSummary(jobs: merged, pushedAt: push.date)
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

    // MARK: - Push Health

    func fetchHealthSummary(for push: Push) async {
        guard healthSummaries[push.id] == nil else { return }
        await loadHealthSummary(for: push)
    }

    private func refreshHealthSummaries(for targets: [Push]) async {
        await withTaskGroup(of: Void.self) { group in
            for push in targets {
                group.addTask { [weak self] in await self?.loadHealthSummary(for: push) }
            }
        }
    }

    private func loadHealthSummary(for push: Push) async {
        let revision = push.revision
        if let summary = try? await gate.run({ try await TreeHerderService.shared.fetchHealthSummary(revision: revision) }) {
            healthSummaries[push.id] = summary
            Task { await prefetchHealth(for: push) }
        }
    }

    /// Push Health takes 12–17s when Treeherder hasn't computed it recently and about a second
    /// after, so a push with failures has it fetched as soon as the list knows about the
    /// failures, before anyone taps the push. Green pushes don't need it: their verdict comes
    /// from the job list.
    func prefetchHealth(for push: Push) async {
        guard healths[push.id] == nil, healthTasks[push.id] == nil, hasFailures(push) else { return }
        if let cached = await HealthCache.load(revision: push.revision) {
            healths[push.id] = cached
            return
        }
        _ = try? await prefetchGate.run { await self.fetchHealth(for: push) }
    }

    /// Shows a finished push's saved Push Health straight away, then asks for a fresh one.
    func openHealth(for push: Push) async {
        if healths[push.id] == nil, let cached = await HealthCache.load(revision: push.revision) {
            healths[push.id] = cached
        }
        await fetchHealth(for: push)
    }

    /// One request per push at a time: opening a push whose prefetch is still running waits on
    /// that request rather than starting a second slow one.
    func fetchHealth(for push: Push) async {
        if let inFlight = healthTasks[push.id] {
            await inFlight.value
            return
        }
        let revision = push.revision
        let task = Task {
            guard let health = try? await TreeHerderService.shared.fetchHealth(revision: revision) else { return }
            healths[push.id] = health
            await HealthCache.save(health, revision: revision)
        }
        healthTasks[push.id] = task
        await task.value
        healthTasks[push.id] = nil
    }

    private func hasFailures(_ push: Push) -> Bool {
        if let summary = healthSummaries[push.id],
           (summary.testFailureCount ?? 0) + (summary.buildFailureCount ?? 0) + (summary.lintFailureCount ?? 0) > 0 {
            return true
        }
        let status = summaries[push.id]?.ringStatus ?? healthSummaries[push.id]?.status ?? [:]
        return SimpleView.failedResults.contains { (status[$0] ?? 0) > 0 }
    }

    // MARK: - One job's failures

    /// Not queued behind the background work: this is someone waiting on a tap.
    func fetchFailures(jobId: Int) async {
        guard suggestions[jobId] == nil else { return }
        async let lines = try? TreeHerderService.shared.fetchBugSuggestions(jobId: jobId)
        async let detail = try? TreeHerderService.shared.fetchJobDetail(jobId: jobId)
        let (fetchedLines, fetchedDetail) = await (lines, detail)
        if let fetchedDetail { jobDetails[jobId] = fetchedDetail }
        suggestions[jobId] = fetchedLines ?? []
    }

    func fetchFirstFailingTest(jobId: Int) async {
        guard firstFailingTest[jobId] == nil else { return }
        let errors = try? await gate.run { try await TreeHerderService.shared.fetchTextLogErrors(jobId: jobId) }
        firstFailingTest[jobId] = errors?.lazy.compactMap { SimpleView.testFromErrorLine($0.line) }.first ?? ""
    }
}

nonisolated struct Person: Codable, Hashable, Sendable {
    let email: String
    let name: String?
}

/// At most `limit` requests in flight, like the web's `queued()`: a push list or a
/// "Seen before" section can otherwise fire dozens at once at a shared service.
actor RequestGate {
    private let limit: Int
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if inFlight >= limit {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            inFlight += 1
        }
        defer {
            if waiting.isEmpty { inFlight -= 1 } else { waiting.removeFirst().resume() }
        }
        return try await work()
    }
}
