import Foundation

enum BuildWatchError: LocalizedError {
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

final class TreeHerderService {
    static let shared = TreeHerderService()

    private let base = "https://treeherder.mozilla.org/api"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "BuildWatch-iOS/1.0 (https://github.com/rcurran/BuildWatch)"
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

    func fetchJobs(pushId: Int) async throws -> [Job] {
        var components = URLComponents(string: "\(base)/project/try/jobs/")!
        components.queryItems = [
            URLQueryItem(name: "push_id",           value: "\(pushId)"),
            URLQueryItem(name: "count",             value: "2000"),
            URLQueryItem(name: "return_type",       value: "list"),
            URLQueryItem(name: "exclusion_profile", value: "false"),
        ]

        let (data, response) = try await session.data(from: components.url!)
        try validateResponse(response)
        return try parseCompactJobs(from: data)
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

    private func parseCompactJobs(from data: Data) throws -> [Job] {
        guard
            let json          = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results       = json["results"] as? [[Any]],
            let propertyNames = json["job_property_names"] as? [String]
        else { return [] }

        var idx: [String: Int] = [:]
        for (i, name) in propertyNames.enumerated() { idx[name] = i }

        return results.compactMap { row -> Job? in
            func str(_ key: String) -> String? { row[safe: idx[key]] as? String }
            func int(_ key: String) -> Int?    { row[safe: idx[key]] as? Int }

            guard
                let id       = int("id"),
                let stateStr = str("state"),
                let platform = str("platform")
            else { return nil }

            return Job(
                id:             id,
                pushId:         int("result_set_id") ?? int("push_id") ?? 0,
                taskId:         str("task_id"),
                platform:       platform,
                platformOption: str("platform_option") ?? "",
                jobTypeName:    str("job_type_name")   ?? "",
                jobTypeSymbol:  str("job_type_symbol") ?? "",
                jobGroupName:   str("job_group_name")  ?? "",
                jobGroupSymbol: str("job_group_symbol") ?? "",
                state:          JobState(rawValue:  stateStr)             ?? .completed,
                result:         JobResult(rawValue: str("result") ?? "") ?? .unknown,
                startTimestamp: int("start_timestamp"),
                endTimestamp:   int("end_timestamp"),
                tier:           int("tier") ?? 1
            )
        }
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BuildWatchError.invalidResponse }
        guard (200..<300).contains(http.statusCode)   else { throw BuildWatchError.httpError(http.statusCode) }
    }
}
