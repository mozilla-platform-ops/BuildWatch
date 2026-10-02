import Foundation

/// The app's words, kept identical to Treeherder's simple view (`ui/simple-view/strings.js`)
/// so the two read the same.
nonisolated enum Strings {

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        n == 1 ? one : (many ?? "\(one)s")
    }

    private static let numberWords = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]

    static func countWord(_ n: Int) -> String {
        n >= 0 && n < numberWords.count ? numberWords[n] : String(n)
    }

    static func capitalize(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    static let feedbackURL = URL(string: "https://github.com/mozilla-platform-ops/BuildWatch/issues/new")!

    enum Nav {
        static let home = "Your pushes"
        static let fullView = "Full view"
        static let darkMode = "Dark mode"
        static func darkModeState(_ on: Bool) -> String { on ? "Dark mode on" : "Dark mode off" }
    }

    enum Footer {
        static let report = "Report a bug or suggestion"
    }

    static let kitAlt = "Kit, the Firefox mascot"

    enum Picker {
        static let title = "Pushes by…"
        static let recent = "Recent"
        static let clear = "Clear"
        static func placeholder(_ hasRecent: Bool) -> String { hasRecent ? "name@mozilla.com" : "you@mozilla.com" }
        static let emailLabel = "Author email"
        static let show = "Show pushes"
        static let openFullView = "Open the full view"
    }

    enum List {
        static func title(_ name: String?) -> String {
            guard let first = name?.split(separator: " ").first else { return "Pushes" }
            return "\(first)’s pushes"
        }
        static func author(_ who: String) -> String { "author: \(who)" }
        static func authorLabel(_ email: String) -> String { "Author \(email), tap to change" }
        static let editShow = "Show"
        static let editCancel = "Cancel"
        static let editRecent = "Recent"
        static func empty(_ author: String) -> String { "Nothing on try from \(author)." }
        static let wrongAddress = "Wrong address? Change it"
        static let unreachable = "Couldn't reach Treeherder."
        static func failing(_ kinds: [String]) -> String { "\(capitalize(kinds.joined(separator: " and "))) failing" }
        static func stillRunning(_ text: String) -> String { "\(text) · still running" }
        static func running(_ done: Int, _ total: Int) -> String { "Running · \(done) of \(total)" }
        static let onlySeenBefore = "Only failures seen before"
        static let green = "All green"
    }

    enum Verdict {
        static func testsBroke(_ n: Int) -> String { "\(countWord(n).lowercased()) \(plural(n, "test")) broke" }
        static func buildsBroke(_ n: Int) -> String { "\(countWord(n).lowercased()) \(plural(n, "build")) broke" }
        static let lintFailed = "lint failed"
        static func sentence(_ parts: [String]) -> String { "\(capitalize(parts.joined(separator: ", ")))." }
        static func soFar(_ done: Int, _ total: Int) -> String { "\(done) of \(total) jobs done so far." }
        static func othersSeenBefore(_ n: Int) -> String {
            " \(countWord(n)) other \(plural(n, "failure has", "failures have")) been seen before."
        }
        static func alsoOnParent(_ n: Int) -> String {
            "\(n) more \(plural(n, "test fails", "tests fail")) on the parent too."
        }
        static let probablyYours = "Nothing here fails on the parent, so it's probably yours."
        static func nothingNewYet(_ soFar: String, _ others: String) -> String { "\(soFar) Nothing new has broken.\(others)" }
        static let stillRunning = "Still running."
        static let nothingNew = "Nothing new broke."
        static func likelyIntermittent(_ n: Int) -> String {
            "\(countWord(n)) \(plural(n, "failure has", "failures have")) been seen before, so \(plural(n, "it's", "they're")) likely intermittent."
        }
        static func failsOnParentToo(_ n: Int) -> String {
            "\(countWord(n)) \(plural(n, "test fails", "tests fail")) here, but on the parent too."
        }
        static let allGreen = "All green."
        static func nothingToLookAt(_ total: Int) -> String { "\(total) \(plural(total, "job")), nothing needs a look." }
    }

    enum Push {
        static let reading = "Reading the results"
        static let ringDone = "done"
        static func ringJobs(_ n: Int) -> String { plural(n, "job") }
        static func elapsed(_ time: String) -> String { "\(time) in" }
        static func commits(_ n: Int) -> String { "\(n) \(plural(n, "commit"))" }
        static let everyJob = "Every job, in the full view"
        static let brokenHere = "Broken here"
        static let builds = "Builds"
        static let lint = "Lint"
        static let alsoOnParent = "Also failing on the parent"
        static let seenBefore = "Seen before"
        static let knownIntermittents = "Known intermittents"
        static let legend: [(key: String, label: String)] = [
            ("testfailed", "failed"),
            ("busted", "busted"),
            ("exception", "exception"),
            ("success", "passed"),
            ("running", "running"),
            ("pending", "pending"),
            ("unscheduled", "waiting on a build"),
        ]
        static let newTag = "New"
        static func failedRuns(_ failed: Int, _ total: Int) -> String { "Failed \(failed) of \(total) \(plural(total, "run"))" }
        static func jobCount(_ n: Int) -> String { "\(n) jobs · " }
    }

    enum Watch {
        static let idle = "Notify me when it finishes"
        static let watching = "Watching. Tap to stop"
    }

    enum Job {
        static let noLines = "No failure lines were parsed for this job. The log has the rest."
        static let newInPush = "New in this push"
        static func seenBefore(_ n: Int) -> String { "Seen \(n) \(plural(n, "time")) before" }
        static let internalBug = "Internal"
        static func moreBugs(_ n: Int) -> String { "\(n) more \(plural(n, "bug"))" }
        static func otherErrors(_ n: Int) -> String { "\(n) other log \(plural(n, "error"))" }
        static let logViewer = "Log viewer"
        static let rawLog = "Raw log"
        static let fullView = "Full view"
    }

    enum ETA {
        static let mostSoon = "Most results any minute."
        static func mostIn(_ min: Int) -> String { "Most results in ~\(min) min." }
        static func mostLine(_ most: String, _ all: String) -> String { "Most by \(most) · all done around \(all)" }
        static func startSoon(_ started: Bool) -> String { "\(started ? "The rest start" : "Tests start") any minute." }
        static func startIn(_ started: Bool, _ min: Int) -> String {
            "\(started ? "The rest start" : "Tests start") in ~\(min) min."
        }
        static func waitingOn(_ n: Int, _ build: String) -> String {
            "\(n) \(plural(n, "job waits", "jobs wait")) on the \(build)"
        }
        static func buildName(_ name: String) -> String { "\(name) build" }
    }

    enum Time {
        static let justNow = "just now"
        static func minutesAgo(_ m: Int) -> String { "\(m)m ago" }
        static func hoursAgo(_ h: Int) -> String { "\(h)h ago" }
        static let yesterday = "yesterday"
        static func daysAgo(_ d: Int) -> String { "\(d)d ago" }
        static func minutes(_ m: Int) -> String { "\(m) min" }
        static func hoursMinutes(_ h: Int, _ m: Int) -> String { "\(h)h \(m)m" }
    }

    static let resultWords = [
        "testfailed": "failed",
        "busted": "broke",
        "exception": "errored",
        "usercancel": "cancelled",
    ]
}
