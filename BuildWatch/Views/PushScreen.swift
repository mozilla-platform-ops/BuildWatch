import SwiftUI

/// One push, the way Treeherder's simple view tells it (`PushDetail.jsx`): a ring of its
/// jobs, one sentence about what broke and whether it's yours, then the failures.
struct PushScreen: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        let health = viewModel.healths[push.id]
        let summary = viewModel.summary(for: push)
        let jobs = viewModel.jobsByPush[push.id]
        let counts = jobs != nil ? summary?.ringStatus : (health?.status ?? viewModel.healthSummaries[push.id]?.status)
        // Everything but the sorting of failures comes from the job list and the row summary,
        // which arrive in well under a second. Only that sorting waits for Push Health.
        let progress = counts.map(SimpleView.progress)
        let running = progress?.running ?? false
        let eta = running ? SimpleView.describe(summary?.eta, started: (progress?.done ?? 0) > 0) : nil

        let tests = health?.metrics.tests.details
        let groups = SimpleView.groupByTest(tests?.needInvestigation ?? [])
        let yours = groups.filter { !$0.failedInParent }
        let parentToo = groups.filter(\.failedInParent)
        let known = SimpleView.groupByTest(tests?.knownIssues ?? [])
        let builds = health?.metrics.builds.details ?? []
        let lint = health?.metrics.linting.details ?? []

        // Push Health only reports failures classified as new (id 6); show the rest too.
        let reported = Set(groups.flatMap(\.jobIds) + known.flatMap(\.jobIds) + builds.map(\.id) + lint.map(\.id))
        let seenBefore = (jobs ?? []).filter {
            $0.tier <= 2 && $0.state == .completed && $0.result.isFailure && !reported.contains($0.id)
        }

        let failedJobs = (jobs ?? []).filter { $0.tier <= 2 && $0.state == .completed && $0.result.isFailure }
        let sorted = health != nil || (jobs != nil && failedJobs.isEmpty)
        let verdict: SimpleView.Verdict? = progress.flatMap { progress in
            sorted
                ? SimpleView.verdict(
                    yours: yours.count, parentToo: parentToo.count, builds: builds.count, lint: !lint.isEmpty,
                    progress: progress, etaHeadline: eta?.headline, seenBefore: seenBefore.count
                )
                : SimpleView.provisionalVerdict(viewModel.healthSummaries[push.id])
        }

        SimplePage(
            backLabel: Strings.List.title(viewModel.personName(viewModel.username) ?? viewModel.authorName),
            fullView: push.treeherderURL,
            refresh: { await reload() }
        ) {
            Text("revision: \(push.shortRevision)")
        } content: {
            header
            hero(counts: counts, progress: progress, verdict: verdict, eta: eta, running: running)

            if let health {
                VStack(alignment: .leading, spacing: 0) {
                    CardSection(title: Strings.Push.brokenHere, count: yours.count) {
                        ForEach(yours) { TestCard(group: $0, health: health, push: push) }
                    }
                    CardSection(title: Strings.Push.builds, count: builds.count) {
                        ForEach(builds) { JobCard(job: $0, push: push) }
                    }
                    CardSection(title: Strings.Push.lint, count: lint.count) {
                        LintCard(jobs: lint, push: push)
                    }
                    CardSection(title: Strings.Push.alsoOnParent, count: parentToo.count, quiet: true) {
                        ForEach(parentToo) { TestCard(group: $0, health: health, push: push) }
                    }
                    CardSection(title: Strings.Push.seenBefore, count: seenBefore.count, quiet: true) {
                        SeenBefore(jobs: seenBefore, push: push)
                    }
                    CardSection(title: Strings.Push.knownIntermittents, count: known.count, quiet: true) {
                        ForEach(known) { TestCard(group: $0, health: health, push: push) }
                    }
                }
                .svRise()
            } else if !failedJobs.isEmpty {
                // Until Push Health has sorted them, the failures as the job list has them, so
                // there's already something to tap.
                CardSection(title: Strings.Push.failures, count: failedJobs.count) {
                    ForEach(failedJobs) { job in
                        JobCard(
                            job: HealthJob(
                                id: job.id, jobTypeName: job.jobTypeName, jobTypeSymbol: job.jobTypeSymbol,
                                platform: job.platform, result: job.result.rawValue
                            ),
                            push: push
                        )
                    }
                }
                .svRise()
            }

            footer
        }
        .task { await watch() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("\(SimpleView.ago(push.date)) · \(push.authorName ?? push.author)")
                .svCaps()
                .foregroundStyle(SV.muted)
            if push.displayTitle != push.shortRevision {
                Text(push.displayTitle)
                    .svFont(17)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .svRise()
    }

    // MARK: - Hero

    private func hero(
        counts: [String: Int]?, progress: SimpleView.Progress?, verdict: SimpleView.Verdict?,
        eta: (headline: String, line: String)?, running: Bool
    ) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let size = min(240, proxy.size.width * 0.64)
                TickRing(status: counts, size: size) {
                    if let progress { RingCenter(progress: progress) }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 240)
            .padding(.bottom, 24)

            if let verdict, let counts {
                VStack(spacing: 0) {
                    Text(verdict.headline)
                        .svFont(30, .bold)
                        .tracking(-0.6)
                        .foregroundStyle(verdict.tone == .quiet ? SV.ink : verdict.tone.text)
                        .contentTransition(.opacity)
                    Text(verdict.sub)
                        .svFont(16)
                        .foregroundStyle(SV.muted)
                        .frame(maxWidth: 300)
                        .padding(.top, 10)
                    Legend(status: counts)
                        .padding(.top, 16)
                    if running {
                        let watched = viewModel.watchedPushIds.contains(push.id)
                        OutlineButton(
                            title: watched ? Strings.Watch.watching : Strings.Watch.idle,
                            filled: watched,
                            fullWidth: false
                        ) {
                            viewModel.toggleWatch(push: push)
                        }
                        .padding(.top, 20)
                    }
                    if let eta {
                        Text(eta.line)
                            .svFont(13, .bold)
                            .monospacedDigit()
                            .foregroundStyle(SV.infoInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(SV.infoBg, in: RoundedRectangle(cornerRadius: SV.radius))
                            .padding(.top, 18)
                    }
                    if running {
                        Text(Strings.Push.elapsed(SimpleView.duration(since: push.date)))
                            .svFont(13)
                            .foregroundStyle(SV.muted)
                            .padding(.top, 8)
                    }
                }
                .multilineTextAlignment(.center)
                .svRise()
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 12) {
                    Skeleton(width: 224, height: 30)
                    Skeleton(width: 144, height: 16)
                }
                .frame(minHeight: 96, alignment: .top)
                .accessibilityElement()
                .accessibilityLabel(Strings.Push.reading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(SV.hairline)
            let commits = push.patchRevisions
            if !commits.isEmpty {
                Commits(revisions: commits)
            }
            TextLink(title: Strings.Push.everyJob, url: push.treeherderURL)
        }
        .padding(.top, 8)
        .padding(.horizontal, 6)
    }

    // MARK: - Data

    private func reload() async {
        async let health: Void = viewModel.fetchHealth(for: push)
        await viewModel.reload(push)
        await health
    }

    /// Reads the push, then keeps it fresh once a minute while it's running, as the web does.
    private func watch() async {
        async let health: Void = viewModel.openHealth(for: push)
        async let summary: Void = viewModel.fetchHealthSummary(for: push)
        await viewModel.fetchJobs(for: push)
        await summary
        await health
        while !Task.isCancelled {
            let running = viewModel.healths[push.id] == nil || (viewModel.summary(for: push)?.isRunning ?? true)
            guard running else { return }
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, scenePhase == .active else { continue }
            await reload()
        }
    }
}

// MARK: - Ring centre and legend

private struct RingCenter: View {
    let progress: SimpleView.Progress
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let target = progress.running
            ? Double(progress.total > 0 ? progress.done * 100 / progress.total : 0)
            : Double(progress.total)

        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                CountUp(value: shown)
                    .font(.system(size: 54, weight: .bold))
                    .tracking(-1.6)
                    .monospacedDigit()
                if progress.running {
                    Text("%").font(.system(size: 28, weight: .bold)).foregroundStyle(SV.muted)
                }
            }
            Text(progress.running ? Strings.Push.ringDone : Strings.Push.ringJobs(progress.total))
                .svCaps()
                .foregroundStyle(SV.muted)
        }
        .onAppear { animate(to: target) }
        .onChange(of: target) { animate(to: target) }
    }

    private func animate(to target: Double) {
        if reduceMotion { shown = target; return }
        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.9)) { shown = target }
    }
}

private struct Legend: View {
    let status: [String: Int]

    var body: some View {
        FlowLayout(alignment: .center, spacing: 16, lineSpacing: 6) {
            ForEach(Strings.Push.legend, id: \.key) { kind, label in
                if let n = status[kind], n > 0 {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Ticks.color(kind))
                            .opacity(kind == "pending" ? 0.45 : 1)
                            .frame(width: 9, height: 9)
                        Text("\(n) \(label)")
                    }
                }
            }
        }
        .svFont(13)
        .monospacedDigit()
        .foregroundStyle(SV.muted)
    }
}

// MARK: - Sections and cards

private struct CardSection<Content: View>: View {
    let title: String
    let count: Int
    var quiet = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: title, count: count)
                VStack(spacing: 8) { content() }
            }
            .opacity(quiet ? 0.75 : 1)
            .padding(.bottom, 28)
        }
    }
}

/// A card that opens in place to show a job's failure summary.
private struct ExpandingCard<Head: View>: View {
    let jobId: Int?
    let push: Push
    var under: String?
    @ViewBuilder var head: (Bool) -> Head
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                head(open)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint(open ? "Collapses the failure summary" : "Shows the failure summary")
            if open, let jobId {
                InlineFailures(jobId: jobId, push: push, under: under)
            }
        }
        .svCard()
    }
}

/// `.sv-test-file` over `.sv-test-dir`.
private struct TestName: View {
    let name: String

    var body: some View {
        let (dir, file) = SimpleView.splitTestPath(name)
        VStack(alignment: .leading, spacing: 2) {
            Text(file).svFont(17, .bold)
            if !dir.isEmpty {
                Text(dir).svFont(13).foregroundStyle(SV.muted)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

/// `.sv-card-meta`: grey details, wrapping, with the chevron pushed to the end.
private struct CardMeta<Lead: View>: View {
    let text: String
    let open: Bool
    @ViewBuilder var lead: () -> Lead

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            lead()
            Text(text)
                .svFont(13)
                .foregroundStyle(SV.muted)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Chevron(open: open)
        }
        .padding(.top, 10)
    }
}

private struct NewTag: View {
    var title = Strings.Push.newTag

    var body: some View {
        Text(title)
            .svFont(11, .bold)
            .textCase(.uppercase)
            .tracking(0.44)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(SV.danger, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// `.sv-runbar`: one cell per run of a test, the failed ones orange.
private struct RunBar: View {
    let failed: Int
    let total: Int

    var body: some View {
        let cells = max(1, min(total, 20))
        let red = Int((Double(failed) / Double(max(total, 1)) * Double(cells)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<cells, id: \.self) { i in
                Capsule()
                    .fill(i < red ? SV.testfailed : SV.hairline)
                    .frame(maxWidth: 22)
                    .frame(height: 6)
            }
        }
        .padding(.top, 12)
        .accessibilityHidden(true)
    }
}

private struct TestCard: View {
    let group: SimpleView.TestGroup
    let health: PushHealth
    let push: Push

    private struct Run: Identifiable {
        let id: Int
        let label: String
    }

    var body: some View {
        let failed = group.jobIds.count
        let runs = group.entries.flatMap { entry in
            entry.failedInJobs.map { id in
                let symbol = health.jobs[entry.jobName]?.first { $0.id == id }?.jobTypeSymbol
                let label = "\(PlatformNames.display(entry.platform)) \(entry.config)"
                return Run(id: id, label: symbol.map { "\(label) · \($0)" } ?? label)
            }
        }
        let meta = "\(Strings.Push.failedRuns(failed, group.totalJobs)) · \(group.platforms.joined(separator: ", ")) · \(group.configs.joined(separator: ", "))"

        ExpandingRuns(runs: runs.map { ($0.id, $0.label) }, push: push, under: group.testName) { open in
            VStack(alignment: .leading, spacing: 0) {
                TestName(name: group.testName)
                RunBar(failed: failed, total: group.totalJobs)
                CardMeta(text: meta, open: open) {
                    if !group.failedInParent { NewTag() }
                }
            }
        }
    }
}

/// A card whose head opens either one job's failures, or a list of runs to choose from.
private struct ExpandingRuns<Head: View>: View {
    let runs: [(id: Int, label: String)]
    let push: Push
    let under: String
    @ViewBuilder var head: (Bool) -> Head
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                head(open)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .buttonStyle(PressStyle())
            if open {
                if runs.count == 1 {
                    InlineFailures(jobId: runs[0].id, push: push, under: under)
                } else {
                    VStack(spacing: 0) {
                        ForEach(runs, id: \.id) { run in
                            Divider().overlay(SV.hairline)
                            RunRow(jobId: run.id, label: Text(run.label), push: push, under: under)
                        }
                    }
                }
            }
        }
        .svCard()
    }
}

/// `.sv-run`: one run of a test, or one lint job, opening its failures in place.
private struct RunRow: View {
    let jobId: Int
    let label: Text
    let push: Push
    var under: String?
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 12) {
                    label.svFont(15).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Chevron(open: open)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
            }
            .buttonStyle(PressStyle())
            if open {
                InlineFailures(jobId: jobId, push: push, under: under)
            }
        }
    }
}

private struct JobCard: View {
    let job: HealthJob
    let push: Push

    var body: some View {
        ExpandingCard(jobId: job.id, push: push) { open in
            VStack(alignment: .leading, spacing: 2) {
                Text(SimpleView.jobShortName(job.jobTypeName)).svFont(17, .bold)
                CardMeta(
                    text: (job.platform == "lint" ? "" : "\(PlatformNames.display(job.platform)) · ")
                        + SimpleView.resultWord(job.result),
                    open: open
                ) { EmptyView() }
            }
        }
    }
}

private struct LintCard: View {
    let jobs: [HealthJob]
    let push: Push

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                if index > 0 { Divider().overlay(SV.hairline) }
                RunRow(
                    jobId: job.id,
                    label: Text("\(SimpleView.jobShortName(job.jobTypeName))\(Text(" · \(SimpleView.resultWord(job.result))").foregroundStyle(SV.muted))"),
                    push: push
                )
            }
        }
        .svCard()
    }
}

/// Failures Push Health didn't report, named by the first failing test in each log.
private struct SeenBefore: View {
    let jobs: [Job]
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel

    var body: some View {
        let groups = grouped
        ForEach(groups, id: \.jobs[0].id) { group in
            let (dir, file) = SimpleView.splitTestPath(group.name)
            let platforms = unique(group.jobs.map { "\(PlatformNames.display($0.platform)) \($0.platformOption)" })
            let meta = (group.jobs.count > 1 ? Strings.Push.jobCount(group.jobs.count) : "")
                + "\(platforms.joined(separator: ", ")) · \(group.jobs.map(\.jobTypeSymbol).joined(separator: ", "))"

            ExpandingCard(jobId: group.jobs[0].id, push: push, under: group.name) { open in
                VStack(alignment: .leading, spacing: 2) {
                    if file.isEmpty {
                        Skeleton()
                    } else {
                        Text(file).svFont(17, .bold).multilineTextAlignment(.leading)
                    }
                    if !dir.isEmpty {
                        Text(dir).svFont(13).foregroundStyle(SV.muted).multilineTextAlignment(.leading)
                    }
                    CardMeta(text: meta, open: open) { EmptyView() }
                }
            }
        }
        .task(id: jobs.map(\.id)) {
            await withTaskGroup(of: Void.self) { tasks in
                for job in jobs {
                    tasks.addTask { await viewModel.fetchFirstFailingTest(jobId: job.id) }
                }
            }
        }
    }

    private var grouped: [(name: String, jobs: [Job])] {
        var order: [String] = []
        var groups: [String: (name: String, jobs: [Job])] = [:]
        for job in jobs {
            let test = viewModel.firstFailingTest[job.id]
            let name = test.map { $0.isEmpty ? SimpleView.jobShortName(job.jobTypeName) : $0 } ?? ""
            let key = name.isEmpty ? "job:\(job.id)" : name
            if groups[key] == nil {
                order.append(key)
                groups[key] = (name, [])
            }
            groups[key]?.jobs.append(job)
        }
        return order.compactMap { groups[$0] }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - A job's failures, in place

/// `JobFailures inline`: the job's failure lines grouped by test, with matching bugs.
private struct InlineFailures: View {
    let jobId: Int
    let push: Push
    var under: String?
    @Environment(DashboardViewModel.self) private var viewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lines = viewModel.suggestions[jobId] {
                let (groups, other) = SimpleView.groupFailureLines(lines)
                if lines.isEmpty {
                    Text(Strings.Job.noLines)
                        .svFont(16)
                        .foregroundStyle(SV.muted)
                        .padding(.vertical, 10)
                }
                ForEach(Array(groups.enumerated()), id: \.element.path) { index, group in
                    if index > 0 { Divider().overlay(SV.hairline) }
                    FailureBlock(group: group, under: under)
                }
                if !other.isEmpty {
                    OtherErrors(lines: other, startsOpen: groups.isEmpty)
                }
                links
            } else {
                Skeleton().padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(SV.wash)
        .overlay(alignment: .top) { SV.hairline.frame(height: 1) }
        .task { await viewModel.fetchFailures(jobId: jobId) }
    }

    private var links: some View {
        let detail = viewModel.jobDetails[jobId]
        var full = "https://treeherder.mozilla.org/jobs?repo=try&revision=\(push.revision)"
        if let task = detail?.taskId { full += "&selectedTaskRun=\(task).\(detail?.retryId ?? 0)" }

        return HStack(spacing: 18) {
            TextLink(title: Strings.Job.logViewer, url: URL(string: "https://treeherder.mozilla.org/logviewer?job_id=\(jobId)&repo=try"))
            if let raw = detail?.rawLogURL {
                TextLink(title: Strings.Job.rawLog, url: raw)
            }
            TextLink(title: Strings.Job.fullView, url: URL(string: full))
        }
    }
}

private struct FailureBlock: View {
    let group: SimpleView.FailureLines
    let under: String?
    @State private var showAll = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let repeats = under.map { !$0.isEmpty && group.path.hasSuffix($0) } ?? false
        let bugs = showAll ? group.bugs : Array(group.bugs.prefix(3))
        let hidden = group.bugs.count - bugs.count

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if !repeats { TestName(name: group.path) }
                ForEach(group.messages, id: \.self) { message in
                    Text(message)
                        .svFont(13, monospaced: true)
                        .lineSpacing(3)
                        .padding(.top, 8)
                        .textSelection(.enabled)
                }
                Group {
                    if group.isNew {
                        if !repeats { NewTag(title: Strings.Job.newInPush) }
                    } else {
                        Text(Strings.Job.seenBefore(group.counter))
                            .svFont(13)
                            .foregroundStyle(SV.muted)
                    }
                }
                .padding(.top, 10)
            }

            if !group.bugs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(bugs.enumerated()), id: \.offset) { index, bug in
                        if index > 0 { Divider().overlay(SV.hairline) }
                        BugRow(bug: bug, path: group.path)
                    }
                    if hidden > 0 {
                        Divider().overlay(SV.hairline)
                        Button(Strings.Job.moreBugs(hidden)) { showAll = true }
                            .svFont(14)
                            .foregroundStyle(SV.link)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
                .svCard()
                .padding(.top, 10)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct BugRow: View {
    let bug: Bug
    let path: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        let summary = SimpleView.bugSummary(bug.summary ?? "", path: path)
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let id = bug.id {
                Text(String(id))
                    .svFont(14, .bold)
                    .monospacedDigit()
                    .strikethrough(!(bug.resolution ?? "").isEmpty)
                    .foregroundStyle(SV.link)
            } else {
                Text(Strings.Job.internalBug).svFont(14).foregroundStyle(SV.muted)
            }
            Text(summary)
                .svFont(14)
                .foregroundStyle(SV.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)

        if let id = bug.id, let url = URL(string: "https://bugzilla.mozilla.org/show_bug.cgi?id=\(id)") {
            Button { openURL(url) } label: { row }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Bug \(id), \(summary)")
        } else {
            row
        }
    }
}

private struct OtherErrors: View {
    let lines: [BugSuggestion]
    let startsOpen: Bool
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? startsOpen
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open = !isOpen }
            } label: {
                Text(Strings.Job.otherErrors(lines.count))
                    .svFont(14)
                    .foregroundStyle(SV.link)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(lines, id: \.lineNumber) { line in
                    Text(line.search)
                        .svFont(13, monospaced: true)
                        .foregroundStyle(SV.muted)
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 12)
    }
}

private struct Commits: View {
    let revisions: [PushRevision]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .svFont(11, .semibold)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(Strings.Push.commits(revisions.count)).svFont(14)
                }
                .foregroundStyle(SV.link)
                .frame(minHeight: 48)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(revisions) { revision in
                    Text(revision.comments.components(separatedBy: "\n").first ?? "")
                        .svFont(14)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
