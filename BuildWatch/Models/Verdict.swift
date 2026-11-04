import Foundation

// Ported from Treeherder's simple view (`helpers.js`, `PushList.jsx`, `PushDetail.jsx`,
// `JobSummary.jsx`) so a push reads the same sentence in both places.

nonisolated enum SimpleView {

    // MARK: - Counting

    private static let notResults: Set<String> = ["completed", "pending", "running", "unscheduled", "coalesced"]
    static let failedResults: Set<String> = ["testfailed", "busted", "exception"]

    static func finishedCount(_ status: [String: Int]) -> Int {
        status.filter { !notResults.contains($0.key) }.values.reduce(0, +)
    }

    struct Progress: Equatable {
        let done: Int
        let left: Int
        var total: Int { done + left }
        var running: Bool { left > 0 }
    }

    static func progress(_ status: [String: Int]) -> Progress {
        Progress(
            done: finishedCount(status),
            left: (status["pending"] ?? 0) + (status["running"] ?? 0) + (status["unscheduled"] ?? 0)
        )
    }

    /// Tier 1 and 2 jobs by state, and finished ones by result.
    static func status(from jobs: [Job]) -> [String: Int] {
        var status = ["completed": 0, "pending": 0, "running": 0, "unscheduled": 0]
        for job in jobs where job.tier <= 2 {
            if job.state == .completed {
                status["completed", default: 0] += 1
                status[job.result.rawValue, default: 0] += 1
            } else {
                status[job.state.rawValue, default: 0] += 1
            }
        }
        return status
    }

    /// Failed jobs split the way the full view's classifications do: still open
    /// (unclassified, some with an error line Treeherder hasn't seen before), or already
    /// classified by a sheriff or the author.
    struct FailureCounts: Equatable, Sendable {
        let failed: Int
        let open: Int
        let new: Int
        var classified: Int { failed - open }

        init(_ jobs: [Job]) {
            let failedJobs = jobs.filter(\.isCountedFailure)
            let openJobs = failedJobs.filter { !$0.isClassified }
            failed = failedJobs.count
            open = openJobs.count
            new = openJobs.filter(\.isNewFailure).count
        }
    }

    // MARK: - Push rows

    static func describe(_ summary: PushSummary?) -> (tone: Tone, text: String) {
        guard let summary else { return (.quiet, "") }
        let counts = summary.failureCounts
        let progress = progress(summary.ringStatus)
        if counts.failed > 0 {
            var parts = [Strings.List.failed(counts.failed)]
            if counts.new > 0 { parts.append(Strings.List.newCount(counts.new)) }
            if counts.open == 0 { parts.append(Strings.List.allClassified) }
            let text = parts.joined(separator: " · ")
            return (counts.open > 0 ? .bad : .quiet, progress.running ? Strings.List.stillRunning(text) : text)
        }
        if progress.running {
            return (.running, Strings.List.running(progress.done, progress.total))
        }
        return (.good, Strings.List.green)
    }

    // MARK: - The verdict

    struct Verdict: Equatable {
        let tone: Tone
        let headline: String
        let sub: String
    }

    /// How many jobs failed and the facts about them, with no guess at whose they are.
    static func verdict(_ counts: FailureCounts, progress: Progress, etaHeadline: String?) -> Verdict {
        typealias V = Strings.Verdict
        let soFar = progress.running ? V.soFar(progress.done, progress.total) : ""

        guard counts.failed > 0 else {
            return progress.running
                ? Verdict(tone: .running, headline: etaHeadline ?? V.stillRunning, sub: V.nothingFailedYet(soFar))
                : Verdict(tone: .good, headline: V.allGreen, sub: V.nothingToLookAt(progress.total))
        }

        let headline = V.jobsFailed(counts.failed)
        if counts.open == 0 {
            let sub = [V.allClassified, soFar].filter { !$0.isEmpty }.joined(separator: " ")
            return Verdict(tone: .quiet, headline: headline, sub: sub)
        }
        let sub = [
            counts.new > 0 ? V.newErrors(counts.new) : "",
            counts.classified > 0 ? V.classified(counts.classified) : "",
            soFar,
        ].filter { !$0.isEmpty }.joined(separator: " ")
        return Verdict(tone: .bad, headline: headline, sub: sub)
    }

    // MARK: - ETA

    static func describe(_ eta: PushETA?, started: Bool, now: Date = Date()) -> (headline: String, line: String)? {
        guard let eta else { return nil }
        switch eta.confidence {
        case .firm:
            let soon = eta.mostResultsBy <= now
            return (
                soon ? Strings.ETA.mostSoon : Strings.ETA.mostIn(minutesUntil(eta.mostResultsBy, now)),
                Strings.ETA.mostLine(eta.mostResultsBy.clockTime, eta.allDoneBy.clockTime)
            )
        case .blockedOnBuild:
            guard let build = eta.blockingBuild else { return nil }
            return (
                build.releasesAt <= now
                    ? Strings.ETA.startSoon(started)
                    : Strings.ETA.startIn(started, minutesUntil(build.releasesAt, now)),
                Strings.ETA.waitingOn(build.blockedJobs, buildName(build.currentStage))
            )
        case .estimating:
            return nil
        }
    }

    private static func minutesUntil(_ date: Date, _ now: Date) -> Int {
        max(1, Int((date.timeIntervalSince(now) / 60).rounded()))
    }

    private static func buildName(_ name: String) -> String {
        var short = name.hasPrefix("build-") ? String(name.dropFirst(6)) : name
        if let slash = short.firstIndex(of: "/") { short = String(short[..<slash]) }
        return Strings.ETA.buildName(short.replacingOccurrences(of: "-", with: " "))
    }

    // MARK: - Words

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, now.timeIntervalSince(date).rounded() / 60)
        if minutes < 1 { return Strings.Time.justNow }
        if minutes < 60 { return Strings.Time.minutesAgo(Int(minutes.rounded())) }
        let hours = minutes / 60
        if hours < 24 { return Strings.Time.hoursAgo(Int(hours.rounded())) }
        let days = Int((hours / 24).rounded())
        return days == 1 ? Strings.Time.yesterday : Strings.Time.daysAgo(days)
    }

    static func duration(since date: Date, now: Date = Date()) -> String {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded())
        if minutes < 60 { return Strings.Time.minutes(minutes) }
        return Strings.Time.hoursMinutes(minutes / 60, minutes % 60)
    }

    static func jobShortName(_ name: String) -> String {
        if name.hasPrefix("source-test-mozlint-") { return String(name.dropFirst(20)) }
        if name.hasPrefix("source-test-") { return String(name.dropFirst(12)) }
        return name
    }

    static func resultWord(_ result: String) -> String {
        Strings.resultWords[result] ?? result
    }

    static func splitTestPath(_ name: String) -> (dir: String, file: String) {
        guard !name.contains("://"), let slash = name.lastIndex(of: "/") else { return ("", name) }
        return (String(name[...slash]), String(name[name.index(after: slash)...]))
    }

    static func testFromErrorLine(_ line: String) -> String? {
        let parts = line.components(separatedBy: " | ")
        guard parts.count >= 2,
              parts[0].contains("TEST-UNEXPECTED") || parts[0].contains("PROCESS-CRASH")
        else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - One job's failure lines

    struct FailureLines {
        let path: String
        var messages: [String] = []
        var isNew = false
        var counter = 0
        var bugs: [Bug] = []
    }

    static func groupFailureLines(_ lines: [BugSuggestion]) -> (groups: [FailureLines], other: [BugSuggestion]) {
        var order: [String] = []
        var tests: [String: FailureLines] = [:]
        var bugKeys: [String: Set<String>] = [:]
        var other: [BugSuggestion] = []

        for line in lines {
            let named = line.pathEnd ?? ""
            guard let path = named.contains("/") || named.contains(".") ? named : testFromErrorLine(line.search) else {
                other.append(line)
                continue
            }
            var group = tests[path] ?? {
                order.append(path)
                return FailureLines(path: path)
            }()
            let message = messageOf(line.search)
            if !group.messages.contains(message) { group.messages.append(message) }
            group.isNew = group.isNew || (line.failureNewInRev ?? false) || line.counter == 0
            group.counter = max(group.counter, line.counter ?? 0)
            for bug in (line.bugs?.openRecent ?? []) + (line.bugs?.allOthers ?? []) {
                let key = bug.id.map(String.init) ?? "internal:\(bug.summary ?? "")"
                if bugKeys[path, default: []].insert(key).inserted { group.bugs.append(bug) }
            }
            tests[path] = group
        }

        let groups = order.compactMap { tests[$0] }.map { group -> FailureLines in
            var group = group
            let real = group.messages.filter { $0.firstMatch(of: /^(profile uploaded in |finished in \d+ms$)/) == nil }
            if !real.isEmpty { group.messages = real }
            return group
        }
        return (groups.filter(\.isNew) + groups.filter { !$0.isNew }, other)
    }

    private static func messageOf(_ search: String) -> String {
        let parts = search.components(separatedBy: " | ")
        return parts.count > 2 ? parts.dropFirst(2).joined(separator: " | ") : search
    }

    static func bugSummary(_ summary: String, path: String) -> String {
        var trimmed = summary.replacing(/^Intermittent\s+/.ignoresCase(), with: "")
        if let range = trimmed.range(of: path) { trimmed.removeSubrange(range) }
        trimmed = trimmed.replacing(/^[\s|]+/, with: "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? summary : trimmed
    }

    static func jobTitle(_ name: String) -> String {
        jobShortName(name).replacing(/^test-[^\/]+\/[^-]+-/, with: "")
    }
}

// MARK: - Push words

extension Push {
    /// The person who pushed, from the "Name <email>" on their commits.
    nonisolated var authorName: String? {
        let people: [(name: String, email: String)] = revisions.compactMap { revision in
            guard let match = revision.author.firstMatch(of: /^\s*(.*?)\s*<([^>]+)>/) else { return nil }
            return (String(match.1), String(match.2).lowercased())
        }
        if let own = people.first(where: { $0.email == author.lowercased() }), !own.name.isEmpty {
            return own.name
        }
        let names = Set(people.map(\.name).filter { !$0.isEmpty })
        return names.count == 1 ? names.first : nil
    }

    /// Commits that are the patch, not the try selector.
    nonisolated var patchRevisions: [PushRevision] {
        revisions.filter { $0.comments.firstMatch(of: /^(?i)(Fuzzy query|try:)/) == nil }
    }

    nonisolated var treeherderURL: URL {
        URL(string: "https://treeherder.mozilla.org/jobs?repo=try&revision=\(revision)")!
    }
}
