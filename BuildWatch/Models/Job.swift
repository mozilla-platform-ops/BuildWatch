import Foundation
import SwiftUI

enum JobResult: String, Codable, Sendable, CaseIterable {
    case success
    case testfailed
    case busted
    case exception
    case retry
    case usercancel
    case unknown

    var color: Color {
        switch self {
        case .success:    Color(red: 0.25, green: 0.88, blue: 0.69)
        case .testfailed: Color(red: 1.0,  green: 0.31, blue: 0.37)
        case .busted:     Color(red: 1.0,  green: 0.58, blue: 0.0)
        case .exception:  Color.purple
        case .retry:      Color.yellow
        case .usercancel, .unknown: Color(uiColor: .systemGray3)
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

enum JobState: String, Codable, Sendable {
    case pending, running, completed
}

struct Job: Identifiable, Codable, Sendable {
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
        guard let d = duration else { return nil }
        let minutes = Int(d / 60)
        let seconds = Int(d.truncatingRemainder(dividingBy: 60))
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
}

struct PlatformGroup: Identifiable, Sendable {
    let platform: String
    let option: String
    var jobs: [Job]

    var id: String { "\(platform)-\(option)" }
    var displayName: String { option.isEmpty ? platform : "\(platform) \(option)" }

    var failureCount: Int { jobs.filter { $0.result.isFailure && $0.state == .completed }.count }
    var pendingCount:  Int { jobs.filter { $0.isPending }.count }
    var runningCount:  Int { jobs.filter { $0.isRunning }.count }
    var successCount:  Int { jobs.filter { $0.result == .success && $0.state == .completed }.count }

    enum OverallStatus {
        case passing, failing, running, pending

        var color: Color {
            switch self {
            case .passing:  Color(red: 0.25, green: 0.88, blue: 0.69)
            case .failing:  Color(red: 1.0,  green: 0.31, blue: 0.37)
            case .running:  Color.blue
            case .pending:  Color(uiColor: .systemGray3)
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
    }

    var overallStatus: OverallStatus {
        if failureCount > 0 { return .failing }
        if runningCount > 0 { return .running }
        if pendingCount > 0 { return .pending }
        return .passing
    }
}
