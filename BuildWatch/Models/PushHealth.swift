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
nonisolated struct PushHealth: Decodable, Sendable {
    let status: [String: Int]
    let metrics: Metrics
    let jobs: [String: [HealthJob]]

    struct Metrics: Decodable, Sendable {
        let tests: Tests
        let builds: Jobs
        let linting: Jobs
    }

    struct Tests: Decodable, Sendable {
        let details: Details

        struct Details: Decodable, Sendable {
            let needInvestigation: [HealthTest]
            let knownIssues: [HealthTest]
        }
    }

    struct Jobs: Decodable, Sendable {
        let details: [HealthJob]
    }
}

nonisolated struct HealthTest: Decodable, Sendable {
    let testName: String
    let jobName: String
    let platform: String
    let config: String
    let totalJobs: Int
    let failedInParent: Bool
    let failedInJobs: [Int]
}

nonisolated struct HealthJob: Decodable, Sendable, Identifiable {
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
