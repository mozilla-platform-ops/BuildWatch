import Foundation

struct TextLogError: Decodable, Identifiable {
    let id: Int
    let line: String
    let lineNumber: Int
    let job: Int

    enum CodingKeys: String, CodingKey {
        case id, line, job
        case lineNumber = "line_number"
    }

    var groupKey: String {
        let parts = line.components(separatedBy: " | ")
        if parts.count >= 2 {
            let prefix = parts[0]
            if prefix.contains("TEST-UNEXPECTED") || prefix.contains("PROCESS-CRASH") {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return String(line.prefix(100)).trimmingCharacters(in: .whitespaces)
    }
}

struct FailureGroup: Identifiable {
    let id: String
    let pattern: String
    let affectedJobCount: Int
    let exampleLine: String
}
