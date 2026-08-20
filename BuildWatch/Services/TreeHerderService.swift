import Foundation

nonisolated enum BuildWatchError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case retriggerFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:  "Invalid response from server"
        case .httpError(let c): "HTTP error \(c)"
        case .retriggerFailed:  "Failed to retrigger job"
        }
    }
}

/// A page of jobs plus the server-supplied watermark needed to ask for the next delta.
///
/// `latestModified` is always TreeHerder's own `last_modified` string — never a device
/// clock reading — so a phone with a skewed clock can't silently skip updates.
nonisolated struct JobsSnapshot: Sendable {
    var jobs: [Job]
    var latestModified: String?

    static let empty = JobsSnapshot(jobs: [], latestModified: nil)
}

/// `nonisolated` on purpose. The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// which previously pinned every request *and* every JSON parse to the main thread — including
/// deserialising a 676 KB, 1,262-row job payload while the user's finger was still on the screen.
/// Marking the service nonisolated moves the network wait and the parse off the main actor;
/// only the finished, `Sendable` result crosses back.
nonisolated final class TreeHerderService: Sendable {
    static let shared = TreeHerderService()

    private let base = "https://treeherder.mozilla.org/api"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": "BuildWatch-iOS/1.0 (https://github.com/mozilla-platform-ops/BuildWatch)"
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - Pushes

    func fetchPushes(count: Int = 20, author: String? = nil) async throws -> [Push] {
        var components = URLComponents(string: "\(base)/project/try/push/")!
        var queryItems = [URLQueryItem(name: "count", value: "\(count)")]
        if let author {
            queryItems.append(URLQueryItem(name: "author", value: author))
        }
        components.queryItems = queryItems

        let (data, response) = try await session.data(from: components.url!)
        try validateResponse(response)
        return try JSONDecoder().decode(PushesResponse.self, from: data).results
    }

    // MARK: - Jobs

    /// Fetches jobs for a push.
    ///
    /// Pass `modifiedSince` (a watermark from a previous `JobsSnapshot`) to fetch only the
    /// jobs that changed since that point. On a 1,262-job push this turns a ~142 KB refresh
    /// into ~1.7 KB, because a poll typically only sees a handful of state transitions.
    ///
    /// TreeHerder parses `last_modified__gt` at second granularity, so the filter is
    /// effectively inclusive of the watermark's own second. We additionally rewind the
    /// watermark by `deltaGuardBand` so a job written in the same second as our previous
    /// read can never fall through the gap — re-sending a few rows is far cheaper than
    /// showing a stale result.
    private static let deltaGuardBand: TimeInterval = 2

    func fetchJobs(pushId: Int, modifiedSince: String? = nil) async throws -> JobsSnapshot {
        var components = URLComponents(string: "\(base)/project/try/jobs/")!
        var queryItems = [
            URLQueryItem(name: "push_id",           value: "\(pushId)"),
            URLQueryItem(name: "count",             value: "2000"),
            URLQueryItem(name: "return_type",       value: "list"),
            URLQueryItem(name: "exclusion_profile", value: "false"),
        ]
        if let watermark = modifiedSince.flatMap(Self.rewind) {
            queryItems.append(URLQueryItem(name: "last_modified__gt", value: watermark))
        }
        components.queryItems = queryItems

        let (data, response) = try await session.data(from: components.url!)
        try validateResponse(response)
        return try parseCompactJobs(from: data)
    }

    /// Steps a `last_modified` watermark back by the guard band, preserving TreeHerder's
    /// `yyyy-MM-dd'T'HH:mm:ss.SSSSSS` shape. Returns the input unchanged if it can't be parsed,
    /// which at worst costs one redundant row.
    static func rewind(_ timestamp: String) -> String {
        guard let date = isoParser.date(from: timestamp) else { return timestamp }
        return isoFormatter.string(from: date.addingTimeInterval(-deltaGuardBand))
    }

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Text Log Errors

    func fetchTextLogErrors(jobId: Int) async throws -> [TextLogError] {
        let url = URL(string: "\(base)/project/try/jobs/\(jobId)/text_log_errors/")!
        let (data, response) = try await session.data(from: url)
        try validateResponse(response)
        return try JSONDecoder().decode([TextLogError].self, from: data)
    }

    // MARK: - Actions

    func retriggerJob(jobId: Int) async throws {
        let url = URL(string: "\(base)/project/try/jobs/\(jobId)/retrigger/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BuildWatchError.retriggerFailed
        }
    }

    // MARK: - Compact Job Parser

    /// Column offsets into TreeHerder's positional job rows, resolved once per response.
    ///
    /// The response carries 37 columns; BuildWatch reads 14. Resolving them up front turns
    /// the hot loop into plain integer indexing instead of one string hash per field per row
    /// (~17k dictionary lookups on a 1,262-job push).
    private struct ColumnMap {
        let id, state, platform, platformOption: Int
        let jobTypeName, jobTypeSymbol, jobGroupName, jobGroupSymbol: Int
        let result, startTimestamp, endTimestamp, tier: Int
        let taskId, resultSetId, pushId, lastModified: Int

        init(_ names: [String]) {
            var lookup: [String: Int] = Dictionary(minimumCapacity: names.count)
            for (i, name) in names.enumerated() { lookup[name] = i }
            func at(_ key: String) -> Int { lookup[key] ?? -1 }

            id              = at("id")
            state           = at("state")
            platform        = at("platform")
            platformOption  = at("platform_option")
            jobTypeName     = at("job_type_name")
            jobTypeSymbol   = at("job_type_symbol")
            jobGroupName    = at("job_group_name")
            jobGroupSymbol  = at("job_group_symbol")
            result          = at("result")
            startTimestamp  = at("start_timestamp")
            endTimestamp    = at("end_timestamp")
            tier            = at("tier")
            taskId          = at("task_id")
            resultSetId     = at("result_set_id")
            pushId          = at("push_id")
            lastModified    = at("last_modified")
        }
    }

    private func parseCompactJobs(from data: Data) throws -> JobsSnapshot {
        guard
            let json          = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results       = json["results"] as? [[Any]],
            let propertyNames = json["job_property_names"] as? [String]
        else { return .empty }

        let col = ColumnMap(propertyNames)
        var latestModified: String?
        var jobs: [Job] = []
        jobs.reserveCapacity(results.count)

        for row in results {
            let count = row.count
            func str(_ i: Int) -> String? { i >= 0 && i < count ? row[i] as? String : nil }
            func int(_ i: Int) -> Int?    { i >= 0 && i < count ? row[i] as? Int    : nil }

            guard
                let id       = int(col.id),
                let stateStr = str(col.state),
                let platform = str(col.platform)
            else { continue }

            if let modified = str(col.lastModified),
               modified > (latestModified ?? "") {
                // Lexicographic max is correct here: the format is fixed-width ISO-8601.
                latestModified = modified
            }

            jobs.append(Job(
                id:             id,
                pushId:         int(col.resultSetId) ?? int(col.pushId) ?? 0,
                taskId:         str(col.taskId),
                platform:       platform,
                platformOption: str(col.platformOption) ?? "",
                jobTypeName:    str(col.jobTypeName)    ?? "",
                jobTypeSymbol:  str(col.jobTypeSymbol)  ?? "",
                jobGroupName:   str(col.jobGroupName)   ?? "",
                jobGroupSymbol: str(col.jobGroupSymbol) ?? "",
                state:          JobState(rawValue:  stateStr)                 ?? .completed,
                result:         JobResult(rawValue: str(col.result) ?? "")    ?? .unknown,
                startTimestamp: int(col.startTimestamp),
                endTimestamp:   int(col.endTimestamp),
                tier:           int(col.tier) ?? 1
            ))
        }

        return JobsSnapshot(jobs: jobs, latestModified: latestModified)
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BuildWatchError.invalidResponse }
        guard (200..<300).contains(http.statusCode)   else { throw BuildWatchError.httpError(http.statusCode) }
    }
}
