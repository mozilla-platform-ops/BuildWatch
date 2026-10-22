import SwiftUI

/// One push, the way Treeherder's simple view tells it (`PushDetail.jsx`): a ring of its
/// jobs, one sentence about what failed, then the failures.
struct PushScreen: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        let summary = viewModel.summary(for: push)
        let jobs = viewModel.jobsByPush[push.id]
        let counts = summary?.ringStatus
        let progress = counts.map(SimpleView.progress)
        let running = progress?.running ?? false
        let eta = running ? SimpleView.describe(summary?.eta, started: (progress?.done ?? 0) > 0) : nil
        let verdict = summary.flatMap { summary in
            progress.map { SimpleView.verdict(summary.failureCounts, progress: $0, etaHeadline: eta?.headline) }
        }

        let failed = (jobs ?? []).filter(\.isCountedFailure)
        let open = failed.filter { !$0.isClassified }
        let classified = failed.filter(\.isClassified)

        SimplePage(
            backLabel: Strings.List.title(viewModel.personName(viewModel.username) ?? viewModel.authorName),
            fullView: push.treeherderURL,
            refresh: { await viewModel.reload(push) }
        ) {
            Text("revision: \(push.shortRevision)")
        } content: {
            header
            hero(counts: counts, progress: progress, verdict: verdict, eta: eta, running: running)

            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CardSection(title: Strings.Push.failures, count: open.count) {
                        FailureList(jobs: open, push: push)
                    }
                    CardSection(title: Strings.Push.classified, count: classified.count, quiet: true) {
                        FailureList(jobs: classified, push: push)
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

    /// Reads the push, then keeps it fresh once a minute while it's running, as the web does.
    private func watch() async {
        await viewModel.fetchJobs(for: push)
        while !Task.isCancelled {
            guard viewModel.summary(for: push)?.isRunning ?? true else { return }
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, scenePhase == .active else { continue }
            await viewModel.reload(push)
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

/// Failed jobs named by the first failing test in each log and grouped, so five red jobs
/// read as the tests they are.
private struct FailureList: View {
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
                    CardMeta(text: meta, open: open) {
                        if group.jobs.contains(where: \.isNewFailure) { NewTag() }
                    }
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
