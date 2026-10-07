import Foundation

nonisolated struct Push: Identifiable, Codable, Hashable, Sendable {
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

    /// The push's title, as Treeherder's simple view picks it: the first commit line that
    /// isn't try syntax, else the fuzzy query, else the revision.
    var displayTitle: String {
        let lines = revisions.map {
            ($0.comments.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
        }
        if let human = lines.first(where: { !$0.isEmpty && $0.firstMatch(of: /^(?i)(Fuzzy query|try:|Try Chooser|Pushed via|Try task config)/) == nil }) {
            return human
        }
        if let query = lines.first?.firstMatch(of: /^Fuzzy query=(.*)/) {
            return String(query.1)
                .replacingOccurrences(of: "&query=", with: " · ")
                .replacing(/[\^$'"]/, with: "")
        }
        return shortRevision
    }

    enum CodingKeys: String, CodingKey {
        case id, revision, author, revisions
        case pushTimestamp = "push_timestamp"
    }
}

nonisolated struct PushRevision: Identifiable, Codable, Hashable, Sendable {
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

nonisolated struct PushesResponse: Decodable, Sendable {
    let results: [Push]
}
