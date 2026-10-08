import Foundation

/// `push/health_summary/`: the per-push counts behind a push row.
nonisolated struct HealthSummary: Decodable, Sendable {
    let testFailureCount: Int?
    let buildFailureCount: Int?
    let lintFailureCount: Int?
    let status: [String: Int]
}

/// `push/health/`: what broke, and whether it also breaks on the parent.
///
/// Push Health only reports failures classified as new (classification 6); the push
/// screen finds the rest itself from the job list and files them under "Seen before".
nonisolated struct PushHealth: Codable, Sendable {
    let status: [String: Int]
    let metrics: Metrics
    let jobs: [String: [HealthJob]]

    struct Metrics: Codable, Sendable {
        let tests: Tests
        let builds: Jobs
        let linting: Jobs
    }

    struct Tests: Codable, Sendable {
        let details: Details

        struct Details: Codable, Sendable {
            let needInvestigation: [HealthTest]
            let knownIssues: [HealthTest]
        }
    }

    struct Jobs: Codable, Sendable {
        let details: [HealthJob]
    }
}

nonisolated struct HealthTest: Codable, Sendable {
    let testName: String
    let jobName: String
    let platform: String
    let config: String
    let totalJobs: Int
    let failedInParent: Bool
    let failedInJobs: [Int]
}

nonisolated struct HealthJob: Codable, Sendable, Identifiable {
    let id: Int
    let jobTypeName: String
    let jobTypeSymbol: String
    let platform: String
    let result: String

    enum CodingKeys: String, CodingKey {
        case id, platform, result
        case jobTypeName = "job_type_name"
        case jobTypeSymbol = "job_type_symbol"
    }
}

/// `jobs/<id>/bug_suggestions/`: one parsed failure line, with the bugs that match it.
nonisolated struct BugSuggestion: Decodable, Sendable {
    let search: String
    let pathEnd: String?
    let lineNumber: Int
    let counter: Int?
    let failureNewInRev: Bool?
    let bugs: Bugs?

    struct Bugs: Decodable, Sendable {
        let openRecent: [Bug]?
        let allOthers: [Bug]?

        enum CodingKeys: String, CodingKey {
            case openRecent = "open_recent"
            case allOthers = "all_others"
        }
    }

    enum CodingKeys: String, CodingKey {
        case search, counter, bugs
        case pathEnd = "path_end"
        case lineNumber = "line_number"
        case failureNewInRev = "failure_new_in_rev"
    }
}

nonisolated struct Bug: Decodable, Sendable, Hashable {
    let id: Int?
    let summary: String?
    let resolution: String?
}

/// `jobs/<id>/`: just enough of a job to link to its log and its place in the full view.
nonisolated struct JobDetail: Decodable, Sendable {
    let id: Int
    let taskId: String?
    let retryId: Int?
    let logs: [Log]?

    struct Log: Decodable, Sendable {
        let name: String
        let url: String
    }

    var rawLogURL: URL? {
        logs?.first { $0.name == "live_backing_log" }.flatMap { URL(string: $0.url) }
    }

    enum CodingKeys: String, CodingKey {
        case id, logs
        case taskId = "task_id"
        case retryId = "retry_id"
    }
}

/// Push Health for finished pushes, kept on disk so a push opened again, even after a relaunch,
/// shows its sections straight away. A running push's health changes minute to minute, so it
/// isn't kept.
nonisolated enum HealthCache {
    private static let limit = 60

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PushHealth", isDirectory: true)
    }

    private static func file(_ revision: String) -> URL {
        directory.appendingPathComponent("\(revision).json")
    }

    static func load(revision: String) async -> PushHealth? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file(revision)) else { return nil }
            return try? JSONDecoder().decode(PushHealth.self, from: data)
        }.value
    }

    static func save(_ health: PushHealth, revision: String) async {
        guard !SimpleView.progress(health.status).running else { return }
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(health) else { return }
            try? data.write(to: file(revision), options: .atomic)

            // Keep the newest few dozen.
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            guard files.count > limit else { return }
            let oldestFirst = files.sorted {
                let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return a < b
            }
            for old in oldestFirst.prefix(files.count - limit) { try? fm.removeItem(at: old) }
        }.value
    }
}
