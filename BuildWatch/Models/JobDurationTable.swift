import Foundation

/// How long each kind of job *runs*, learned offline from real try pushes.
///
/// Run time is the one genuinely predictable part of a try push: measured across 369 try
/// pushes and 73,864 jobs, a job's duration has a median coefficient of variation of 5%,
/// and a plain per-job-type median predicts a held-out run to within 5% at the median.
/// Queue *wait* is the unpredictable part, and that is estimated live per worker pool from
/// the push itself — see `PushETA`.
///
/// Shipping this table is what makes the estimate work. The same estimator built purely
/// from the push's own completed jobs lands within ±25% only 12% of the time; with the
/// table it is 63%. There is no runtime cost — one bundled JSON read, lazily, once.
///
/// Regenerate with `tools/generate-duration-table.py`.
nonisolated final class JobDurationTable: Sendable {

    static let shared = JobDurationTable()

    private let exact: [String: Double]
    private let family: [String: Double]
    private let platform: [String: Double]
    private let fallback: Double

    /// Used when the bundle resource is missing entirely — the global median job.
    private static let hardFallback: Double = 20.8

    private init() {
        guard
            let url = Bundle.main.url(forResource: "JobDurations", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            exact = [:]; family = [:]; platform = [:]; fallback = Self.hardFallback
            return
        }
        exact    = decoded.exact
        family   = decoded.family
        platform = decoded.platform
        fallback = decoded.global
    }

    private struct Payload: Decodable {
        let exact: [String: Double]
        let family: [String: Double]
        let platform: [String: Double]
        let global: Double
    }

    /// Expected run time in seconds, most specific match first.
    ///
    /// The `family` tier exists because chunked suites are named `…-wdspec-headless-1`,
    /// `…-2`, and so on. Collapsing the chunk number lets a chunk BuildWatch has never seen
    /// inherit its siblings' timing, which cuts the table's miss rate from 14% to 8%.
    func expectedRunTime(for job: Job) -> TimeInterval {
        let minutes = exact[job.jobTypeName]
            ?? family[Self.familyKey(job.jobTypeName)]
            ?? platform["\(job.platform)|\(job.platformOption)"]
            ?? fallback
        return minutes * 60
    }

    /// Strips a trailing chunk number: `…-wdspec-headless-1` → `…-wdspec-headless`.
    static func familyKey(_ jobTypeName: String) -> String {
        guard let dash = jobTypeName.lastIndex(of: "-") else { return jobTypeName }
        let suffix = jobTypeName[jobTypeName.index(after: dash)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return jobTypeName }
        return String(jobTypeName[..<dash])
    }
}
