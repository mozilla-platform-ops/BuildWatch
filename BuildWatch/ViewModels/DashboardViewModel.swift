import Foundation
import UserNotifications

@Observable
final class DashboardViewModel {

    var pushes: [Push] = []
    var jobsByPush: [Int: [Job]] = [:]
    var failureLinesByPush: [Int: [TextLogError]] = [:]
    var isRefreshing = false
    var errorMessage: String?
    var lastRefresh: Date?
    var watchedPushIds: Set<Int> = []

    private var notifiedPushIds: Set<Int> = []

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

    // MARK: - Computed

    func platformGroups(for push: Push) -> [PlatformGroup] {
        let jobs = jobsByPush[push.id] ?? []
        var groups: [String: PlatformGroup] = [:]
        for job in jobs where job.tier == 1 {
            let key = "\(job.platform)-\(job.platformOption)"
            if groups[key] == nil {
                groups[key] = PlatformGroup(platform: job.platform, option: job.platformOption, jobs: [])
            }
            groups[key]?.jobs.append(job)
        }
        return groups.values.sorted { $0.displayName < $1.displayName }
    }

    func failureCount(_ push: Push) -> Int {
        (jobsByPush[push.id] ?? []).filter { $0.result.isFailure && $0.state == .completed }.count
    }

    func isRunning(_ push: Push) -> Bool {
        (jobsByPush[push.id] ?? []).contains { $0.state == .running || $0.state == .pending }
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
        UserDefaults.standard.set(Array(watchedPushIds), forKey: "watchedPushIds")
    }

    private func checkCompletion(for push: Push) {
        guard watchedPushIds.contains(push.id),
              !notifiedPushIds.contains(push.id),
              let jobs = jobsByPush[push.id],
              !jobs.isEmpty,
              !jobs.contains(where: { $0.state == .running || $0.state == .pending })
        else { return }

        notifiedPushIds.insert(push.id)
        watchedPushIds.remove(push.id)
        UserDefaults.standard.set(Array(watchedPushIds), forKey: "watchedPushIds")

        let failures = jobs.filter { $0.result.isFailure }.count
        sendNotification(for: push, failures: failures)
    }

    private func sendNotification(for push: Push, failures: Int) {
        let content = UNMutableNotificationContent()
        content.title = failures == 0 ? "Try push passed" : "Try push failed"
        content.body = push.displayTitle
        content.sound = .default
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
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    // MARK: - Data Loading

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            let author = username.isEmpty ? nil : username
            pushes = try await TreeHerderService.shared.fetchPushes(count: 20, author: author)
            lastRefresh = Date()
            // Clear cached jobs for watched pushes so completion is re-checked
            for push in pushes where watchedPushIds.contains(push.id) {
                jobsByPush.removeValue(forKey: push.id)
            }
            for push in pushes.prefix(5) {
                Task { await fetchJobs(for: push) }
            }
            for push in pushes.dropFirst(5) where watchedPushIds.contains(push.id) {
                Task { await fetchJobs(for: push) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchJobs(for push: Push) async {
        guard jobsByPush[push.id] == nil else { return }
        do {
            jobsByPush[push.id] = try await TreeHerderService.shared.fetchJobs(pushId: push.id)
            checkCompletion(for: push)
        } catch {}
    }

    func fetchFailureLines(for push: Push) async {
        guard failureLinesByPush[push.id] == nil else { return }
        let failed = Array((jobsByPush[push.id] ?? [])
            .filter { $0.result.isFailure && $0.state == .completed }
            .prefix(15))
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

    func retrigger(job: Job) async throws {
        try await TreeHerderService.shared.retriggerJob(jobId: job.id)
    }
}
