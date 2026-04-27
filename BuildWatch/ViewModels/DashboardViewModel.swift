import Foundation

@Observable
final class DashboardViewModel {

    var pushes: [Push] = []
    var jobsByPush: [Int: [Job]] = [:]
    var isRefreshing = false
    var errorMessage: String?
    var lastRefresh: Date?

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
            for push in pushes.prefix(5) {
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
        } catch {}
    }

    func retrigger(job: Job) async throws {
        try await TreeHerderService.shared.retriggerJob(jobId: job.id)
    }
}
