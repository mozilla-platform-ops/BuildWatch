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
