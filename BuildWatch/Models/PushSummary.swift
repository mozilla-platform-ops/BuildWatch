import Foundation

/// Everything the UI needs to know about a push's jobs, derived once when the jobs land.
///
/// These values used to be computed properties on the view model, recalculated inside
/// `body`. Rendering one push row ran three full passes over that push's job array
/// (platform grouping + sort, failure count, running check), and because `jobsByPush`
/// is `@Observable`, one push's jobs arriving invalidated every visible row. On a
/// 1,262-job push that is a lot of work between the finger and the pixels.
nonisolated struct PushSummary: Sendable {

    /// Tier-1 platform groups — what the dots and the detail list actually show.
    let groups: [PlatformGroup]

    let failureCount: Int
    let runningCount: Int
    let pendingCount: Int
    let successCount: Int
    let totalCount: Int

    /// Tier 2+ jobs are excluded from `groups`, so they are counted separately rather
    /// than silently folded into the headline numbers. Previously the push row's red
    /// badge counted every tier while the dots beside it only covered tier 1, so a push
    /// could show "3" in red next to eight green dots.
    let lowerTierTotal: Int
    let lowerTierFailures: Int

    /// Tier 2+ jobs still running or pending.
    ///
    /// Counted because completion has to account for them even though the dots and the
    /// platform groups deliberately don't. Tier 2 is not a rounding error: across 30
    /// consecutive real try pushes every single one carried tier-2 jobs, and one of them
    /// was 209 tier-1 against 545 tier-2. Leaving these out of `isRunning` meant a push
    /// was declared finished the moment its tier-1 jobs landed — firing "Try push passed"
    /// with hundreds of jobs still going, and consuming the one-shot watch so no
    /// correction ever arrived.
    let lowerTierActive: Int

    var isRunning: Bool { runningCount > 0 || pendingCount > 0 || lowerTierActive > 0 }
    var hasJobs: Bool { totalCount > 0 || lowerTierTotal > 0 }
    var isComplete: Bool { hasJobs && !isRunning }

    static let empty = PushSummary(jobs: [])

    init(jobs: [Job]) {
        var byPlatform: [String: [Job]] = [:]
        var failures = 0, running = 0, pending = 0, successes = 0, total = 0
        var otherTotal = 0, otherFailures = 0, otherActive = 0

        for job in jobs {
            guard job.tier == 1 else {
                otherTotal += 1
                switch job.state {
                case .running, .pending: otherActive += 1
                case .completed:         if job.result.isFailure { otherFailures += 1 }
                }
                continue
            }

            total += 1
            switch job.state {
            case .pending: pending += 1
            case .running: running += 1
            case .completed:
                if job.result.isFailure        { failures += 1 }
                else if job.result == .success { successes += 1 }
            }

            byPlatform["\(job.platform)-\(job.platformOption)", default: []].append(job)
        }

        groups = byPlatform.values
            .map { PlatformGroup(platform: $0[0].platform, option: $0[0].platformOption, jobs: $0) }
            .sorted { $0.displayName < $1.displayName }

        failureCount   = failures
        runningCount   = running
        pendingCount   = pending
        successCount   = successes
        totalCount     = total
        lowerTierTotal = otherTotal
        lowerTierFailures = otherFailures
        lowerTierActive = otherActive
    }

    /// Spoken summary for the push row, so a VoiceOver user hears the same thing the
    /// row of coloured dots shows a sighted user.
    var accessibilityLabel: String {
        guard hasJobs else { return "jobs still loading" }
        var parts: [String] = []
        if failureCount > 0 { parts.append("\(failureCount) failed") }
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if pendingCount > 0 { parts.append("\(pendingCount) pending") }
        if successCount > 0 { parts.append("\(successCount) passed") }
        if parts.isEmpty { parts.append("\(totalCount) jobs") }
        if lowerTierFailures > 0 { parts.append("\(lowerTierFailures) tier 2 failed") }
        if lowerTierActive > 0 { parts.append("\(lowerTierActive) tier 2 still running") }
        return parts.joined(separator: ", ")
    }
}
