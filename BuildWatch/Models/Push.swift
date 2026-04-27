import Foundation

struct Push: Identifiable, Codable, Sendable {
    let id: Int
    let revision: String
    let author: String
    let pushTimestamp: Int
    let revisions: [PushRevision]

    var shortRevision: String { String(revision.prefix(12)) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(pushTimestamp)) }

    var authorHandle: String {
        author.components(separatedBy: "@").first ?? author
    }

    var firstCommitMessage: String {
        revisions.first?.shortMessage ?? ""
    }

    // Human-readable title: prefers a real patch commit over try-selector boilerplate
    var displayTitle: String {
        for revision in revisions {
            let msg = revision.shortMessage.trimmingCharacters(in: .whitespaces)
            guard !msg.isEmpty else { continue }
            if !msg.hasPrefix("Fuzzy") && !msg.hasPrefix("try:") && !msg.hasPrefix("a=try") {
                return msg
            }
        }
        return Self.cleanTryMessage(revisions.first?.shortMessage ?? "")
    }

    private static func cleanTryMessage(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("Fuzzy ") { s = String(s.dropFirst(6)) }
        if s.hasPrefix("try: ")  { s = String(s.dropFirst(5)) }
        if let range = s.range(of: "query=") { s = String(s[range.upperBound...]) }
        return s.components(separatedBy: " ")
            .map { $0.hasPrefix("'") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .trimmingCharacters(in: .whitespaces)
    }

    enum CodingKeys: String, CodingKey {
        case id, revision, author, revisions
        case pushTimestamp = "push_timestamp"
    }
}

struct PushRevision: Identifiable, Codable, Sendable {
    var id: String { revision }
    let revision: String
    let author: String
    let comments: String

    var shortMessage: String {
        comments.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? comments
    }

    var bugNumber: String? {
        let pattern = #"Bug (\d+)"#
        guard let range = comments.range(of: pattern, options: .regularExpression) else { return nil }
        return String(comments[range]).components(separatedBy: " ").last
    }
}

struct PushesResponse: Decodable, Sendable {
    let results: [Push]
}
