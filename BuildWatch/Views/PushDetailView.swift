import SwiftUI

struct PushDetailView: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var selectedFilter: JobFilter = .all
    @State private var safariURL: SafariURL?
    @State private var showFailureSummary = false

    enum JobFilter: String, CaseIterable {
        case all      = "All"
        case failures = "Failures"
        case running  = "Running"

        var systemImage: String {
            switch self {
            case .all:      "list.bullet"
            case .failures: "xmark.circle"
            case .running:  "gearshape"
            }
        }
    }

    private var summary: PushSummary? { viewModel.summary(for: push) }
    private var failedJobs: [Job] {
        (viewModel.jobsByPush[push.id] ?? []).filter { $0.result.isFailure && $0.state == .completed }
    }

    var body: some View {
        List {
            pushHeader
            actionsSection
            jobsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(push.shortRevision)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { filterToolbar }
        .task { await viewModel.fetchJobs(for: push) }
        .refreshable { await viewModel.poll() }
        .sheet(item: $safariURL) { item in SafariView(url: item.url) }
        .sheet(isPresented: $showFailureSummary) {
            FailureSummaryView(push: push)
                .environment(viewModel)
        }
    }

    // MARK: - Push Header

    private var pushHeader: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(push.author, systemImage: "person.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(push.date.timeAgo())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(push.revisions) { revision in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.shortMessage)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(3)

                        HStack(spacing: 8) {
                            Text(String(revision.revision.prefix(12)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Revision \(String(revision.revision.prefix(12)))")

                            if let bugNum = revision.bugNumber {
                                Button("Bug \(bugNum)") {
                                    safariURL = SafariURL(url: URL(string: "https://bugzilla.mozilla.org/show_bug.cgi?id=\(bugNum)")!)
                                }
                                .font(.caption)
                                .accessibilityHint("Opens Bugzilla")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let summary {
                    PushSummaryBar(summary: summary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section("Quick Actions") {
            Button {
                showFailureSummary = true
            } label: {
                Label("Failure Summary", systemImage: "list.bullet.rectangle.portrait")
            }
            .disabled(failedJobs.isEmpty)

            Button {
                safariURL = SafariURL(url: treeherderURL)
            } label: {
                Label("Open in TreeHerder", systemImage: "arrow.up.right.square")
            }

            if let bugURL {
                Button {
                    safariURL = SafariURL(url: bugURL)
                } label: {
                    Label("Open Bug", systemImage: "ant.fill")
                }
            }
        }
    }

    // MARK: - Jobs

    @ViewBuilder
    private var jobsSection: some View {
        let groups = filteredGroups

        if summary == nil {
            Section {
                HStack {
                    ProgressView()
                    Text("Loading jobs…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading jobs")
            }
        } else if groups.isEmpty {
            Section {
                ContentUnavailableView(
                    selectedFilter == .failures ? "No Failures" : "No Running Jobs",
                    systemImage: selectedFilter == .failures ? "checkmark.circle" : "checkmark"
                )
            }
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(filteredJobs(in: group)) { job in
                        JobRowView(job: job)
                    }
                } header: {
                    PlatformGroupHeader(group: group)
                }
            }
        }
    }

    // MARK: - Filtering

    private var filteredGroups: [PlatformGroup] {
        (summary?.groups ?? []).filter { group in
            switch selectedFilter {
            case .all:      return true
            case .failures: return group.failureCount > 0
            case .running:  return group.runningCount > 0 || group.pendingCount > 0
            }
        }
    }

    private func filteredJobs(in group: PlatformGroup) -> [Job] {
        switch selectedFilter {
        case .all:      return group.jobs
        case .failures: return group.jobs.filter { $0.result.isFailure }
        case .running:  return group.jobs.filter { $0.isRunning || $0.isPending }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var filterToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(JobFilter.allCases, id: \.self) { filter in
                    Label(filter.rawValue, systemImage: filter.systemImage).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Filter jobs")
        }
    }

    // MARK: - Helpers

    private var treeherderURL: URL {
        URL(string: "https://treeherder.mozilla.org/#/jobs?repo=try&revision=\(push.revision)")!
    }

    private var bugURL: URL? {
        for revision in push.revisions {
            let msg = revision.comments
            guard let range = msg.range(of: #"Bug (\d+)"#, options: .regularExpression) else { continue }
            guard let bugId = String(msg[range]).components(separatedBy: " ").last else { continue }
            return URL(string: "https://bugzilla.mozilla.org/show_bug.cgi?id=\(bugId)")
        }
        return nil
    }
}

// MARK: - Job Row

struct JobRowView: View {
    let job: Job
    @State private var safariURL: SafariURL?

    var body: some View {
        HStack(spacing: 10) {
            statusGlyph
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.jobTypeName)
                    .font(.subheadline)
                    .lineLimit(1)

                timingLabel
            }

            Spacer()

            if job.result.isFailure {
                Text(job.result.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(job.result.color)
            }

            if let taskId = job.taskId {
                Button {
                    safariURL = SafariURL(url: taskURL(taskId))
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(job.jobTypeName) in Taskcluster")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(job.accessibilityLabel)
        .accessibilityActions {
            if let taskId = job.taskId {
                Button("Open in Taskcluster") { safariURL = SafariURL(url: taskURL(taskId)) }
            }
        }
        .contextMenu {
            if let taskId = job.taskId {
                Button("Open in Taskcluster") { safariURL = SafariURL(url: taskURL(taskId)) }
            }
        }
        .sheet(item: $safariURL) { item in SafariView(url: item.url) }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job.state {
        case .running:
            Image(systemName: "gearshape.fill")
                .foregroundStyle(StatusPalette.running)
                .symbolEffect(.rotate)
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundStyle(.secondary)
        case .completed:
            Image(systemName: job.result.systemImage)
                .foregroundStyle(job.result.color)
        }
    }

    /// Completed jobs show their duration; running jobs now tick their elapsed time once a
    /// second. Previously a running job showed no timing at all, so a job 20 seconds in and
    /// a job wedged for 40 minutes looked exactly the same.
    @ViewBuilder
    private var timingLabel: some View {
        if job.state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let elapsed = job.elapsedString(asOf: context.date) {
                    Text(elapsed)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StatusPalette.running)
                        .contentTransition(.numericText())
                }
            }
        } else if let duration = job.durationString {
            Text(duration)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func taskURL(_ taskId: String) -> URL {
        URL(string: "https://firefox-ci-tc.services.mozilla.com/tasks/\(taskId)")!
    }
}

// MARK: - Platform Group Header

struct PlatformGroupHeader: View {
    let group: PlatformGroup

    var body: some View {
        HStack {
            Image(systemName: group.overallStatus.systemImage)
                .foregroundStyle(group.overallStatus.color)
                .font(.caption.weight(.semibold))

            Text(group.displayName)

            Spacer()

            HStack(spacing: 8) {
                if group.failureCount > 0 {
                    Label("\(group.failureCount)", systemImage: "xmark")
                        .foregroundStyle(StatusPalette.failed)
                }
                if group.runningCount > 0 {
                    Label("\(group.runningCount)", systemImage: "gearshape.fill")
                        .foregroundStyle(StatusPalette.running)
                }
                if group.successCount > 0 {
                    Label("\(group.successCount)", systemImage: "checkmark")
                        .foregroundStyle(StatusPalette.success)
                }
            }
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.accessibilityLabel)
    }
}

// MARK: - Push Summary Bar

struct PushSummaryBar: View {
    let summary: PushSummary

    var body: some View {
        HStack(spacing: 12) {
            chip(count: summary.successCount, color: StatusPalette.success, icon: "checkmark.circle.fill")
            chip(count: summary.failureCount, color: StatusPalette.failed,  icon: "xmark.circle.fill")
            chip(count: summary.runningCount, color: StatusPalette.running, icon: "gearshape.fill")
            chip(count: summary.pendingCount, color: .secondary,            icon: "clock.fill")
            Spacer()
            Text(totalLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel)
    }

    /// Tier 2+ is called out rather than folded in, because the platform groups below
    /// only list tier 1.
    private var totalLabel: String {
        summary.lowerTierTotal > 0
            ? "\(summary.totalCount) jobs · +\(summary.lowerTierTotal) tier 2"
            : "\(summary.totalCount) jobs"
    }

    private func chip(count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text("\(count)")
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(count > 0 ? color : Color(uiColor: .systemGray4))
        .contentTransition(.numericText())
    }
}
