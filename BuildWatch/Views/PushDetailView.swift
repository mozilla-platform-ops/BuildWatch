import SwiftUI

struct PushDetailView: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var selectedFilter: JobFilter = .all
    @State private var showRetriggerAlert = false
    @State private var jobToRetrigger: Job?
    @State private var isRetriggering = false
    @State private var actionError: String?

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
        .alert("Retrigger Job?", isPresented: $showRetriggerAlert, presenting: jobToRetrigger) { job in
            Button("Retrigger") { Task { await retrigger(job: job) } }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text("Retrigger \"\(job.jobTypeName)\" on \(job.platformDisplay)?")
        }
        .alert("Error", isPresented: .init(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
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

                            if let bugNum = revision.bugNumber {
                                Link("Bug \(bugNum)", destination: URL(string: "https://bugzilla.mozilla.org/show_bug.cgi?id=\(bugNum)")!)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let jobs = viewModel.jobsByPush[push.id] {
                    PushSummaryBar(jobs: jobs)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section("Quick Actions") {
            Button {
                Task { await retriggerAllFailed() }
            } label: {
                Label("Retrigger All Failed", systemImage: "arrow.clockwise")
            }
            .disabled((viewModel.jobsByPush[push.id] ?? []).filter { $0.result.isFailure }.isEmpty)

            Link(destination: treeherderURL) {
                Label("Open in TreeHerder", systemImage: "arrow.up.right.square")
            }

            if let bugURL {
                Link(destination: bugURL) {
                    Label("Open Bug", systemImage: "ant.fill")
                }
            }
        }
    }

    // MARK: - Jobs

    @ViewBuilder
    private var jobsSection: some View {
        let groups = filteredGroups

        if viewModel.jobsByPush[push.id] == nil {
            Section {
                HStack {
                    ProgressView()
                    Text("Loading jobs…").foregroundStyle(.secondary)
                }
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
                        JobRowView(job: job) {
                            jobToRetrigger = job
                            showRetriggerAlert = true
                        }
                    }
                } header: {
                    PlatformGroupHeader(group: group)
                }
            }
        }
    }

    // MARK: - Filtering

    private var filteredGroups: [PlatformGroup] {
        viewModel.platformGroups(for: push).filter { group in
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

    private func retrigger(job: Job) async {
        isRetriggering = true
        defer { isRetriggering = false }
        do {
            try await viewModel.retrigger(job: job)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func retriggerAllFailed() async {
        let failed = (viewModel.jobsByPush[push.id] ?? []).filter { $0.result.isFailure }
        for job in failed {
            try? await viewModel.retrigger(job: job)
        }
        viewModel.jobsByPush.removeValue(forKey: push.id)
        await viewModel.fetchJobs(for: push)
    }
}

// MARK: - Job Row

struct JobRowView: View {
    let job: Job
    var onRetrigger: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if job.state == .running {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.blue)
                        .symbolEffect(.rotate)
                } else if job.state == .pending {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: job.result.systemImage)
                        .foregroundStyle(job.result.color)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.jobTypeName)
                    .font(.subheadline)
                    .lineLimit(1)

                if let duration = job.durationString {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if job.result.isFailure {
                Text(job.result.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(job.result.color)
            }

            if let taskId = job.taskId {
                Link(destination: URL(string: "https://firefox-ci-tc.services.mozilla.com/tasks/\(taskId)")!) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if let onRetrigger {
                Button {
                    onRetrigger()
                } label: {
                    Label("Retrigger", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if let taskId = job.taskId {
                Link("Open in Taskcluster", destination: URL(string: "https://firefox-ci-tc.services.mozilla.com/tasks/\(taskId)")!)
            }
            if let onRetrigger {
                Button("Retrigger") { onRetrigger() }
            }
        }
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
                        .foregroundStyle(.red)
                }
                if group.runningCount > 0 {
                    Label("\(group.runningCount)", systemImage: "gearshape.fill")
                        .foregroundStyle(.blue)
                }
                if group.successCount > 0 {
                    Label("\(group.successCount)", systemImage: "checkmark")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Push Summary Bar

struct PushSummaryBar: View {
    let jobs: [Job]

    private var successCount: Int { jobs.filter { $0.result == .success }.count }
    private var failureCount: Int { jobs.filter { $0.result.isFailure }.count }
    private var runningCount: Int { jobs.filter { $0.isRunning }.count }
    private var pendingCount: Int { jobs.filter { $0.isPending }.count }
    private var total: Int { jobs.count }

    var body: some View {
        HStack(spacing: 12) {
            chip(count: successCount, color: .green,     icon: "checkmark.circle.fill")
            chip(count: failureCount, color: .red,       icon: "xmark.circle.fill")
            chip(count: runningCount, color: .blue,      icon: "gearshape.fill")
            chip(count: pendingCount, color: .secondary, icon: "clock.fill")
            Spacer()
            Text("\(total) jobs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chip(count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text("\(count)")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(count > 0 ? color : Color(uiColor: .systemGray4))
    }
}
