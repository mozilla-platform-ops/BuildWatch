import Foundation
import SwiftUI

nonisolated enum JobResult: String, Codable, Sendable, CaseIterable {
    case success
    case testfailed
    case busted
    case exception
    case retry
    case usercancel
    case unknown

    var color: Color {
        switch self {
        case .success:    StatusPalette.success
        case .testfailed: StatusPalette.failed
        case .busted:     StatusPalette.busted
        case .exception:  StatusPalette.exception
        case .retry:      StatusPalette.retry
        case .usercancel, .unknown: StatusPalette.idle
        }
    }

    var systemImage: String {
        switch self {
        case .success:    "checkmark.circle.fill"
        case .testfailed: "xmark.circle.fill"
        case .busted:     "exclamationmark.triangle.fill"
        case .exception:  "bolt.circle.fill"
        case .retry:      "arrow.clockwise.circle.fill"
        case .usercancel: "minus.circle.fill"
        case .unknown:    "questionmark.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .success:    "Success"
        case .testfailed: "Test Failed"
        case .busted:     "Busted"
        case .exception:  "Exception"
        case .retry:      "Retry"
        case .usercancel: "Cancelled"
        case .unknown:    "Unknown"
        }
    }

    var isFailure: Bool {
        self == .testfailed || self == .busted || self == .exception
    }
}

nonisolated enum JobState: String, Codable, Sendable {
    case pending, running, completed
}

nonisolated struct Job: Identifiable, Codable, Sendable {
    let id: Int
    let pushId: Int
    let taskId: String?
    let platform: String
    let platformOption: String
    let jobTypeName: String
    let jobTypeSymbol: String
    let jobGroupName: String
    let jobGroupSymbol: String
    let state: JobState
    let result: JobResult
    let startTimestamp: Int?
    let endTimestamp: Int?
    let tier: Int

    var startDate: Date? {
        startTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var duration: TimeInterval? {
        guard let s = startTimestamp, let e = endTimestamp, e > s else { return nil }
        return TimeInterval(e - s)
    }

    var durationString: String? {
        duration.map(Self.format)
    }

    /// Wall-clock time a still-running job has been going, measured from its start stamp.
    /// A running job previously showed no timing at all, so "stuck for 40 minutes" and
    /// "started 20 seconds ago" were indistinguishable at a glance.
    func elapsed(asOf now: Date = Date()) -> TimeInterval? {
        guard state == .running, let start = startDate else { return nil }
        let seconds = now.timeIntervalSince(start)
        return seconds > 0 ? seconds : nil
    }

    func elapsedString(asOf now: Date = Date()) -> String? {
        elapsed(asOf: now).map(Self.format)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return minutes == 0 ? "\(seconds)s" : "\(minutes)m \(seconds)s"
    }

    var isRunning: Bool { state == .running }
    var isPending: Bool { state == .pending }

    var displayResult: JobResult {
        state == .completed ? result : .unknown
    }

    var platformDisplay: String {
        platformOption.isEmpty ? platform : "\(platform) \(platformOption)"
    }

    /// Spoken status, so VoiceOver conveys what the coloured glyph conveys visually.
    var statusDescription: String {
        switch state {
        case .pending:   "pending"
        case .running:   elapsedString().map { "running for \($0)" } ?? "running"
        case .completed: durationString.map { "\(result.displayName), took \($0)" } ?? result.displayName
        }
    }

    var accessibilityLabel: String {
        "\(jobTypeName), \(platformDisplay), \(statusDescription)"
    }
}

nonisolated struct PlatformGroup: Identifiable, Sendable {
    let platform: String
    let option: String
    let jobs: [Job]

    // Counts are resolved once at construction. They were previously computed properties,
    // so a single group header re-filtered its whole job array four times on every frame.
    let failureCount: Int
    let pendingCount: Int
    let runningCount: Int
    let successCount: Int

    init(platform: String, option: String, jobs: [Job]) {
        self.platform = platform
        self.option = option
        self.jobs = jobs

        var failures = 0, pending = 0, running = 0, successes = 0
        for job in jobs {
            switch job.state {
            case .pending: pending += 1
            case .running: running += 1
            case .completed:
                if job.result.isFailure      { failures += 1 }
                else if job.result == .success { successes += 1 }
            }
        }
        failureCount = failures
        pendingCount = pending
        runningCount = running
        successCount = successes
    }

    var id: String { "\(platform)-\(option)" }
    var displayName: String { option.isEmpty ? platform : "\(platform) \(option)" }

    enum OverallStatus {
        case passing, failing, running, pending

        var color: Color {
            switch self {
            case .passing:  StatusPalette.success
            case .failing:  StatusPalette.failed
            case .running:  StatusPalette.running
            case .pending:  StatusPalette.idle
            }
        }

        var systemImage: String {
            switch self {
            case .passing:  "checkmark.circle.fill"
            case .failing:  "xmark.circle.fill"
            case .running:  "arrow.trianglehead.clockwise.rotate.90"
            case .pending:  "clock.fill"
            }
        }

        /// Distinct silhouettes for the status dots, used when the reader has asked the
        /// system to differentiate without colour. The dots were previously identical
        /// circles, so status was carried by hue alone.
        var dotSymbol: String {
            switch self {
            case .passing:  "checkmark"
            case .failing:  "xmark"
            case .running:  "circle.dotted"
            case .pending:  "minus"
            }
        }

        var description: String {
            switch self {
            case .passing:  "passing"
            case .failing:  "failing"
            case .running:  "running"
            case .pending:  "pending"
            }
        }
    }

    var overallStatus: OverallStatus {
        if failureCount > 0 { return .failing }
        if runningCount > 0 { return .running }
        if pendingCount > 0 { return .pending }
        return .passing
    }

    var accessibilityLabel: String {
        var parts = ["\(displayName), \(overallStatus.description)"]
        if failureCount > 0 { parts.append("\(failureCount) failed") }
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if pendingCount > 0 { parts.append("\(pendingCount) pending") }
        if successCount > 0 { parts.append("\(successCount) passed") }
        return parts.joined(separator: ", ")
    }
}
