import SwiftUI

struct TryPushesView: View {
    @State private var viewModel = DashboardViewModel()
    @Environment(\.scenePhase) private var scenePhase

    /// Poll cadence. Fast while something is still building, slow once everything settled,
    /// so a push that finishes while you're looking at the list turns green on its own
    /// instead of waiting for a manual pull.
    private static let activeInterval: Duration = .seconds(30)
    private static let idleInterval: Duration = .seconds(120)

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.username.isEmpty {
                    noUsernameView
                } else if viewModel.isRefreshing && viewModel.pushes.isEmpty {
                    loadingView
                } else if let error = viewModel.errorMessage, viewModel.pushes.isEmpty {
                    errorView(error)
                } else if !viewModel.isRefreshing && viewModel.pushes.isEmpty {
                    emptyView
                } else {
                    pushList
                }
            }
            .navigationTitle(viewModel.usernameHandle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .task {
                guard !viewModel.username.isEmpty else { return }
                await viewModel.refresh()
                await pollLoop()
            }
        }
        .environment(viewModel)
        .sensoryFeedback(trigger: viewModel.haptic) { _, signal in
            signal.tick == 0 ? nil : signal.event.feedback
        }
    }

    /// Runs for as long as the tab is on screen; SwiftUI cancels the enclosing `.task`
    /// on disappear, and we skip work whenever the app isn't frontmost.
    private func pollLoop() async {
        while !Task.isCancelled {
            let interval = viewModel.anyPushRunning ? Self.activeInterval : Self.idleInterval
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, scenePhase == .active else { continue }
            await viewModel.poll()
        }
    }

    // MARK: - Push List

    private var pushList: some View {
        List {
            ForEach(viewModel.pushes) { push in
                NavigationLink(destination: PushDetailView(push: push)) {
                    PushRowView(push: push)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    let watched = viewModel.watchedPushIds.contains(push.id)
                    Button {
                        viewModel.toggleWatch(push: push)
                    } label: {
                        Label(watched ? "Unwatch" : "Watch", systemImage: watched ? "bell.slash.fill" : "bell.fill")
                    }
                    .tint(watched ? .gray : .orange)
                }
                .task { await viewModel.fetchJobs(for: push) }
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refresh() }
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5)
            Text("Loading pushes…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading pushes")
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No Try Pushes",
            systemImage: "tray",
            description: Text("No recent try pushes found for \(viewModel.username).")
        )
    }

    private var noUsernameView: some View {
        ContentUnavailableView {
            Label("Set Your Mozilla Email", systemImage: "person.crop.circle")
        } description: {
            Text("Add your Mozilla email in Settings to view your try pushes.")
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Pushes", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await viewModel.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if let last = viewModel.lastRefresh {
                    Text(last.shortTimeAgo())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Last updated \(last.timeAgo())")
                }
                if viewModel.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.8)
                        .accessibilityLabel("Refreshing")
                } else {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.username.isEmpty)
                    .accessibilityLabel("Refresh")
                }
            }
        }
    }
}

// MARK: - Push Row

struct PushRowView: View {
    let push: Push
    @Environment(DashboardViewModel.self) private var viewModel

    var body: some View {
        let summary = viewModel.summary(for: push)

        VStack(alignment: .leading, spacing: 6) {
            Text(push.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(push.authorHandle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.watchedPushIds.contains(push.id) {
                    Image(systemName: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                PlatformStatusDots(groups: summary?.groups ?? [], isLoading: summary == nil)

                statusBadge(summary)

                Text(push.date.shortTimeAgo())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(summary))
        .accessibilityHint("Opens jobs for this push")
        .accessibilityActions {
            Button(viewModel.watchedPushIds.contains(push.id) ? "Unwatch" : "Watch") {
                viewModel.toggleWatch(push: push)
            }
        }
    }

    /// One spoken sentence carrying everything the row shows visually — the title, who
    /// pushed it, how old it is, and the status the coloured dots encode. Before this the
    /// row read out as its title plus a bare number, with the dots announced as nothing
    /// at all.
    private func accessibilityLabel(_ summary: PushSummary?) -> String {
        var parts = [push.displayTitle, "by \(push.authorHandle)", push.date.timeAgo()]
        parts.append(summary?.accessibilityLabel ?? "jobs still loading")
        if viewModel.watchedPushIds.contains(push.id) { parts.append("watched") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func statusBadge(_ summary: PushSummary?) -> some View {
        if let summary {
            if summary.failureCount > 0 {
                Text("\(summary.failureCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(StatusPalette.failed, in: Capsule())
            } else if summary.isRunning {
                Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                    .font(.caption)
                    .foregroundStyle(StatusPalette.running)
                    .symbolEffect(.rotate)
            } else if summary.hasJobs {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(StatusPalette.success)
            }
        }
    }
}

// MARK: - Platform Status Dots

struct PlatformStatusDots: View {
    let groups: [PlatformGroup]
    let isLoading: Bool

    /// When the reader has asked iOS to convey information without relying on colour,
    /// swap the identical circles for distinct silhouettes (✓ ✗ ⋯ −).
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Dots track the reader's text size instead of being frozen at 8pt.
    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 8

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            if isLoading {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(Color(uiColor: .systemGray5))
                        .frame(width: dotSize, height: dotSize)
                        .opacity(pulse ? 0.35 : 1)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 0.9).repeatForever().delay(Double(index) * 0.08),
                            value: pulse
                        )
                }
                .onAppear { pulse = true }
            } else {
                ForEach(groups.prefix(8)) { group in
                    dot(for: group)
                }
            }
        }
        .accessibilityHidden(true)   // the parent row speaks this content as one phrase
    }

    @ViewBuilder
    private func dot(for group: PlatformGroup) -> some View {
        if differentiateWithoutColor {
            Image(systemName: group.overallStatus.dotSymbol)
                .font(.system(size: dotSize, weight: .black))
                .foregroundStyle(group.overallStatus.color)
                .frame(width: dotSize + 3, height: dotSize + 3)
        } else {
            Circle()
                .fill(group.overallStatus.color)
                .frame(width: dotSize, height: dotSize)
        }
    }
}
