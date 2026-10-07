import Foundation
import SafariServices
import SwiftUI

// Safe array subscript — handles optional indices from dictionary lookups
extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}

extension Date {
    func timeAgo() -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    func shortTimeAgo() -> String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

extension String {
    var isValidEmail: Bool {
        contains("@") && contains(".")
    }
}

// MARK: - In-App Browser

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct SafariURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Formatting

extension TimeInterval {
    /// `"2h 15m"`, `"45m"`, `"< 1m"` — tight enough for a countdown that ticks.
    nonisolated var etaCountdown: String {
        let minutes = Int((self / 60).rounded(.down))
        if minutes < 1 { return "< 1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Spelled out, for VoiceOver.
    nonisolated var etaSpoken: String {
        let minutes = Int((self / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60, rest = minutes % 60
        var text = "\(hours) hour\(hours == 1 ? "" : "s")"
        if rest > 0 { text += " \(rest) minute\(rest == 1 ? "" : "s")" }
        return text
    }
}

extension Date {
    /// `15:48` or `3:48 PM`, per the reader's locale.
    nonisolated var clockTime: String {
        formatted(date: .omitted, time: .shortened)
    }

    /// Same, but says the day when the estimate runs past midnight — a backed-up hardware
    /// pool really can push a try job into tomorrow, and "3:48 AM" alone reads as a bug.
    nonisolated var etaShortClock: String {
        Calendar.current.isDateInToday(self)
            ? clockTime
            : "\(formatted(.dateTime.weekday(.abbreviated))) \(clockTime)"
    }
}
